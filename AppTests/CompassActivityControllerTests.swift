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
    await controller.updateAppearance(appearance)
    let changed = try #require(system.handle.updates.last)
    #expect(changed.bearing == original.bearing)
    #expect(changed.sampleTime == original.sampleTime)
    #expect(changed.expiry == original.expiry)
    #expect(changed.appearance?.showDegrees == false)
    time = time.addingTimeInterval(6)
    appearance.showDegrees = true
    await controller.updateAppearance(appearance)
    #expect(system.handle.updates.last?.bearing == nil)
    #expect(system.handle.updates.last?.expiry == original.expiry)
    await controller.end()
    let count = system.handle.updates.count
    await controller.updateAppearance(appearance)
    #expect(system.handle.updates.count == count)
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
    time = time.addingTimeInterval(1)
    let heartbeat = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time)
    await controller.update(.init(sample: heartbeat, status: .usable))
    #expect(system.handle.updates.count == 2)
    #expect(system.handle.updates.last?.expiry == time.addingTimeInterval(5))
    await controller.update(.init(sample: nil, status: .slow))
    #expect(system.handle.updates.last?.bearing == nil)
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
  var ends = 0
  var finalState: CompassActivityAttributes.ContentState?
  func update(_ state: CompassActivityAttributes.ContentState) async { updates.append(state) }
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
