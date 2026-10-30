import CompassCore
import Foundation
import Testing
@testable import Compass

@Suite @MainActor
struct CompassActivityControllerTests {
  @Test func appearanceChangesPreserveSampleExpiryAndCannotReviveStaleCourse() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time)
    await controller.update(.init(sample: sample, status: .usable))
    let original = try #require(system.handle.updates.last)
    var appearance = AppearanceValues()
    appearance.showDegrees = false
    time = time.addingTimeInterval(0.5)
    await controller.updateAppearance(appearance)?.value
    let changed = try #require(system.handle.updates.last)
    #expect(changed.bearing == original.bearing)
    #expect(changed.sampleTime == original.sampleTime)
    #expect(changed.expiry == original.expiry)
    #expect(changed.appearance?.showDegrees == false)
    time = time.addingTimeInterval(6)
    appearance.showDegrees = true
    await controller.updateAppearance(appearance)?.value
    #expect(system.handle.updates.last?.bearing == nil)
    #expect(system.handle.updates.last?.expiry == original.expiry)
    await controller.end()
    let count = system.handle.updates.count
    await controller.updateAppearance(appearance)?.value
    #expect(system.handle.updates.count == count)
  }

  @Test func queuedAppearanceCannotRepublishAfterSensorInvalidation() async throws {
    let system = TestActivitySystem()
    let time = Date(timeIntervalSince1970: 100)
    var watchInvalidation = false
    var invalidationBegan = false
    let controller = CompassActivityController(
      system: system,
      now: {
        if watchInvalidation { invalidationBegan = true }
        return time
      })
    try await controller.start()
    system.handle.suspendNextUpdate = true
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time)
    let usable = Task { await controller.update(.init(sample: sample, status: .usable)) }
    while system.handle.resumeUpdate == nil { await Task.yield() }
    var appearance = AppearanceValues()
    appearance.showDegrees = false
    let cosmetic = controller.updateAppearance(appearance)
    watchInvalidation = true
    let invalidation = Task { await controller.update(.init(sample: nil, status: .slow)) }
    // now() runs synchronously before the invalidation joins the serial queue.
    while !invalidationBegan { await Task.yield() }
    system.handle.resumeUpdate?.resume()
    await usable.value
    await cosmetic?.value
    await invalidation.value
    #expect(system.handle.updates.count == 2)
    #expect(system.handle.updates.last?.bearing == nil)
    #expect(system.handle.updates.last?.status == .slow)
    #expect(system.handle.updates.last?.appearance?.showDegrees == false)
  }

  @Test func disabledAndRequestFailureAreReported() async {
    let system = TestActivitySystem()
    let controller = CompassActivityController(system: system)
    system.enabled = false
    await #expect(throws: CompassActivityController.Failure.self) { try await controller.start() }
    #expect(system.requests == 0)
    system.enabled = true
    system.fail = true
    await #expect(throws: CompassActivityController.Failure.self) { try await controller.start() }
    #expect(system.requests == 1)
  }

  @Test func duplicateStartsSurvivorsDismissalAndLateUpdates() async throws {
    let system = TestActivitySystem()
    let controller = CompassActivityController(system: system)
    await controller.end()
    #expect(system.cleanups == 1)
    #expect(system.finalState == .init(bearing: nil, status: .unavailable))
    try await controller.start()
    try await controller.start()
    #expect(system.requests == 1)
    var dismissed = false
    controller.onDismiss = { dismissed = true }
    system.handle.onDismiss?()
    #expect(dismissed)
    await controller.update(.init(sample: nil, status: .waiting))
    #expect(system.handle.updates.isEmpty)
  }

  @Test func cancelledStartupDisposesItsResult() async throws {
    let system = TestActivitySystem()
    system.suspend = true
    let controller = CompassActivityController(system: system)
    let startup = Task { try await controller.start() }
    while system.resume == nil { await Task.yield() }
    await controller.end()
    system.resume?.resume()
    await #expect(throws: CompassActivityController.Failure.self) { try await startup.value }
    #expect(system.handle.ends == 1)
    #expect(system.handle.finalState == .init(bearing: nil, status: .unavailable))
  }

  @Test func laggedTimestampsAndInFlightPushesNeverLetTheStaleDateLapse() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    // Location timestamps precede delivery; an unchanged reading must still refresh in time.
    for delivery in 0..<6 {
      time = Date(timeIntervalSince1970: 100 + Double(delivery))
      let sample = try #require(
        CompassSample(
          degrees: 270, source: .vehicleCourse, reference: .trueNorth,
          accuracy: 1, timestamp: time.addingTimeInterval(-1.5)))
      await controller.update(.init(sample: sample, status: .usable))
      let expiry = try #require(system.handle.updates.last?.expiry)
      #expect(expiry > time)
    }
    #expect(system.handle.updates.count == 3)
    // A reading queued behind a slow push is compared with what the card is about to show.
    system.handle.suspendNextUpdate = true
    time = time.addingTimeInterval(1)
    let turned = CompassSample(
      degrees: 300, source: .vehicleCourse, reference: .trueNorth, accuracy: 1, timestamp: time)
    let slow = Task { await controller.update(.init(sample: turned, status: .usable)) }
    while system.handle.resumeUpdate == nil { await Task.yield() }
    time = time.addingTimeInterval(1)
    let back = CompassSample(
      degrees: 270, source: .vehicleCourse, reference: .trueNorth, accuracy: 1, timestamp: time)
    let queued = Task { await controller.update(.init(sample: back, status: .usable)) }
    system.handle.resumeUpdate?.resume()
    await slow.value
    await queued.value
    #expect(system.handle.updates.suffix(2).map(\.bearing) == [300, 270])
    #expect(CompassActivityController.sameReading(22.4, 22.4))
    #expect(!CompassActivityController.sameReading(22.4, 22.5))
    #expect(CompassActivityController.sameReading(359.6, 0.2))
    await controller.end()
  }

  @Test func rejectsWrongSourceReferenceAndFuturePayload() {
    let now = Date(timeIntervalSince1970: 100)
    for (source, reference, timestamp) in [
      (CompassSource.deviceHeading, NorthReference.trueNorth, now),
      (.vehicleCourse, .magnetic, now),
      (.vehicleCourse, .trueNorth, now.addingTimeInterval(1)),
    ] {
      let sample = CompassSample(
        degrees: 42, source: source, reference: reference,
        accuracy: 1, timestamp: timestamp)
      let state = CompassActivityController.content(
        .init(sample: sample, status: .usable), now: now)
      #expect(state.bearing == nil)
      #expect(state.status == .unavailable)
    }
  }

  @Test func payloadPrivacyFreshnessAndInvalidationBypassThrottle() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time)
    await controller.update(.init(sample: sample, status: .usable))
    await controller.update(.init(sample: sample, status: .usable))
    #expect(system.handle.updates.count == 1)
    #expect(system.handle.updates[0].expiry == time.addingTimeInterval(5))
    let encoded = try JSONEncoder().encode(system.handle.updates[0])
    let decoded = try JSONDecoder().decode(
      CompassActivityAttributes.ContentState.self, from: encoded)
    #expect(decoded == system.handle.updates[0])
    func usable(_ degrees: Double) -> TravelPresentation {
      let sample = CompassSample(
        degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
        accuracy: 1, timestamp: time)
      return .init(sample: sample, status: .usable)
    }
    // The same displayed reading is not pushed again while its stale date has time left.
    time = time.addingTimeInterval(1)
    await controller.update(usable(42.4))
    #expect(system.handle.updates.count == 1)
    time = time.addingTimeInterval(1)
    await controller.update(usable(43))
    #expect(system.handle.updates.count == 2)
    #expect(system.handle.updates.last?.bearing == 43)
    #expect(system.handle.updates.last?.expiry == time.addingTimeInterval(5))
    time = time.addingTimeInterval(0.5)
    await controller.update(usable(44))
    #expect(system.handle.updates.count == 2)
    time = time.addingTimeInterval(1.5)
    await controller.update(usable(43.2))
    #expect(system.handle.updates.count == 2)
    // Two seconds before the pushed stale date lapses, the same reading refreshes it.
    time = time.addingTimeInterval(1)
    await controller.update(usable(43.2))
    #expect(system.handle.updates.count == 3)
    #expect(system.handle.updates.last?.bearing == 43.2)
    #expect(system.handle.updates.last?.expiry == time.addingTimeInterval(5))
    await controller.update(.init(sample: nil, status: .slow))
    #expect(system.handle.updates.last?.bearing == nil)
    #expect(system.handle.updates.count == 4)
    // Recovery after invalidation is a changed reading, not a repeat.
    time = time.addingTimeInterval(0.5)
    await controller.update(usable(43))
    #expect(system.handle.updates.count == 4)
    time = time.addingTimeInterval(0.5)
    await controller.update(usable(43))
    #expect(system.handle.updates.count == 5)
    #expect(system.handle.updates.last?.bearing == 43)
    time = time.addingTimeInterval(6)
    await controller.update(.init(sample: sample, status: .usable))
    #expect(system.handle.updates.last?.bearing == nil)
    await controller.end()
    #expect(system.handle.finalState == .init(bearing: nil, status: .unavailable))
    #expect(system.finalState == .init(bearing: nil, status: .unavailable))
    let count = system.handle.updates.count
    await controller.update(.init(sample: sample, status: .usable))
    #expect(system.handle.updates.count == count)
  }
}

@MainActor private final class TestActivityHandle: CompassActivityHandle {
  var onDismiss: (() -> Void)?
  var updates: [CompassActivityAttributes.ContentState] = []
  var suspendNextUpdate = false
  var resumeUpdate: CheckedContinuation<Void, Never>?
  var ends = 0
  var finalState: CompassActivityAttributes.ContentState?
  func update(_ state: CompassActivityAttributes.ContentState) async {
    updates.append(state)
    if suspendNextUpdate {
      suspendNextUpdate = false
      await withCheckedContinuation { resumeUpdate = $0 }
    }
  }
  func end(_ finalState: CompassActivityAttributes.ContentState) async {
    self.finalState = finalState
    ends += 1
  }
}

@MainActor private final class TestActivitySystem: CompassActivitySystem {
  var enabled = true
  var fail = false
  var suspend = false
  var resume: CheckedContinuation<Void, Never>?
  var requests = 0
  var cleanups = 0
  var finalState: CompassActivityAttributes.ContentState?
  let handle = TestActivityHandle()
  func request(_ state: CompassActivityAttributes.ContentState) async throws
    -> any CompassActivityHandle
  {
    requests += 1
    if suspend { await withCheckedContinuation { resume = $0 } }
    if fail { throw CompassActivityController.Failure.unavailable }
    return handle
  }
  func endSurvivors(_ finalState: CompassActivityAttributes.ContentState) async {
    self.finalState = finalState
    cleanups += 1
  }
}
