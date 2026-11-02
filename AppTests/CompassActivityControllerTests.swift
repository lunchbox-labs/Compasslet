import CompassCore
import Foundation
import Testing
@testable import Compass

@Suite @MainActor
struct CompassActivityControllerTests {
  @Test func stopsAndMissingCourseKeepOriginalReadingUntilNextValidSample() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time)
    await controller.update(.init(sample: sample, status: .usable))
    let original = try #require(system.handle.updates.last)
    #expect(original.expiry == nil)
    for status in [TravelStatus.slow, .unreliable, .unavailable] {
      time += 60
      await controller.update(.init(sample: nil, status: status))
      #expect(system.handle.updates.last == original)
    }
    let next = CompassSample(
      degrees: 90, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time)
    await controller.update(.init(sample: next, status: .usable))
    #expect(system.handle.updates.last?.bearing == 90)
    #expect(system.handle.updates.last?.sampleTime == time)
    await controller.end()
    try await controller.start()
    let count = system.handle.updates.count
    await controller.update(.init(sample: nil, status: .slow))
    #expect(system.handle.updates.count == count + 1)
    #expect(system.handle.updates.last?.bearing == nil)
    await controller.end()
  }

  @Test func appearanceChangesKeepOriginalLastReadingTimestamp() async throws {
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
    appearance.lockScreenTimestamp = .hidden
    appearance.smallActivityTimestamp = .elapsed
    time = time.addingTimeInterval(0.5)
    await controller.updateAppearance(appearance)?.value
    let changed = try #require(system.handle.updates.last)
    #expect(changed.bearing == original.bearing)
    #expect(changed.sampleTime == original.sampleTime)
    #expect(changed.expiry == original.expiry)
    #expect(changed.appearance?.showDegrees == false)
    #expect(changed.appearance?.lockScreenTimestamp == .hidden)
    #expect(changed.appearance?.smallActivityTimestamp == .elapsed)
    time = time.addingTimeInterval(6)
    appearance.showDegrees = true
    await controller.updateAppearance(appearance)?.value
    #expect(system.handle.updates.last?.bearing == original.bearing)
    #expect(system.handle.updates.last?.sampleTime == original.sampleTime)
    #expect(system.handle.updates.last?.expiry == nil)
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
    let invalidation = Task { await controller.invalidateReading() }
    // now() runs synchronously before the invalidation joins the serial queue.
    while !invalidationBegan { await Task.yield() }
    system.handle.resumeUpdate?.resume()
    await usable.value
    await cosmetic?.value
    await invalidation.value
    #expect(system.handle.updates.count == 2)
    #expect(system.handle.updates.last?.bearing == nil)
    #expect(system.handle.updates.last?.status == .unavailable)
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

  @Test func unchangedReadingsDoNotRenewTheRecordedSampleTime() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    // New accepted input remains fresh, but unchanged displayed directions need no heartbeat.
    for delivery in 0..<6 {
      time = Date(timeIntervalSince1970: 100 + Double(delivery))
      let sample = try #require(
        CompassSample(
          degrees: 270, source: .vehicleCourse, reference: .trueNorth,
          accuracy: 1, timestamp: time.addingTimeInterval(-1.5)))
      await controller.update(.init(sample: sample, status: .usable))
      #expect(system.handle.updates.last?.expiry == nil)
      #expect(system.handle.updates.last?.sampleTime == Date(timeIntervalSince1970: 98.5))
    }
    #expect(system.handle.updates.count == 1)
    await controller.end()
  }

  @Test func deliveredReadingsChangeAtRoundedDegreeBoundariesAndWrapNorth() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    for degrees in [22.1, 22.4, 22.5, 359.6, 0.2] {
      let sample = CompassSample(
        degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
        accuracy: 1, timestamp: time)
      await controller.update(.init(sample: sample, status: .usable))
      time += 1
    }
    #expect(system.handle.updates.map(\.bearing) == [22.1, 22.5, 359.6])
    #expect(
      system.handle.updates.map(\.sampleTime)
        == [100.0, 102, 103].map(Date.init(timeIntervalSince1970:)))
    await controller.end()
  }

  @Test func queuedReadingsCompareWithTheLastScheduledDirection() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    var evaluations = 0
    let controller = CompassActivityController(
      system: system,
      now: {
        evaluations += 1
        return time
      })
    try await controller.start()
    func reading(_ degrees: Double) -> TravelPresentation {
      .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracy: 1, timestamp: time), status: .usable)
    }

    system.handle.suspendNextUpdate = true
    let first = reading(300)
    let slow = Task { await controller.update(first) }
    while system.handle.resumeUpdate == nil { await Task.yield() }

    time = time.addingTimeInterval(1)
    let second = reading(270)
    let beforeSecond = evaluations
    let queued = Task { await controller.update(second) }
    // now() runs before the first suspension in update(), on this same main actor.
    // Observing its call proves the second reading has joined the queue.
    while evaluations == beforeSecond { await Task.yield() }

    time = time.addingTimeInterval(1)
    let third = reading(300)
    let beforeThird = evaluations
    let returned = Task { await controller.update(third) }
    while evaluations == beforeThird { await Task.yield() }
    // The first write is still suspended: comparing against its content would
    // incorrectly suppress the return to 300 after the queued 270-degree reading.
    #expect(system.handle.updates.map(\.bearing) == [300])
    system.handle.resumeUpdate?.resume()
    await slow.value
    await queued.value
    await returned.value
    #expect(system.handle.updates.map(\.bearing) == [300, 270, 300])
    await controller.end()
  }

  @Test func activityReadingsSpeakOnlyShownReadingsAsRecordedTravel() {
    func presentation(
      _ status: CompassActivityAttributes.Status, bearing: Double? = nil, isStale: Bool = false,
      appearance: AppearanceValues? = nil
    ) -> CompassActivityReading {
      CompassActivityReading(
        state: .init(
          bearing: bearing, status: status, sampleTime: nil, expiry: nil, appearance: appearance),
        isStale: isStale)
    }
    let usable = presentation(.usable, bearing: 45.4)
    #expect(usable.reading == .init(point: .northeast, roundedDegrees: 45))
    #expect(usable.bearing == "NE 45°")
    #expect(
      usable.spokenDescription
        == "45 degrees, northeast, last recorded travel direction, true north")
    #expect(presentation(.usable, bearing: 359.6).bearing == "N 0°")
    // A stale payload, any non-usable status, or an out-of-range bearing is never spoken as a
    // recorded travel direction; each falls back to its visible status line.
    let withoutReading =
      [presentation(.usable, bearing: 45, isStale: true)]
      + [CompassActivityAttributes.Status.waiting, .slow, .unreliable, .unavailable].map {
        presentation($0, bearing: 45)
      } + [Double.nan, .infinity, -1, 360].map { presentation(.usable, bearing: $0) }
    for value in withoutReading {
      #expect(value.reading == nil)
      #expect(value.bearing == "—")
      #expect(!value.spokenDescription.contains("last recorded"))
      #expect(value.spokenDescription == "\(value.status), travel direction, true north")
    }
    #expect(
      presentation(.usable, bearing: 45, isStale: true).status == presentation(.unavailable).status)
    let statuses = [CompassActivityAttributes.Status.waiting, .slow, .unreliable, .unavailable]
      .map { presentation($0).status }
    #expect(Set(statuses).count == statuses.count)
    // Shorter forms are offered only when both fields are shown, and never without a reading.
    #expect(usable.bearingCandidates == ["NE 45°", "45°", "NE"])
    #expect(presentation(.waiting).bearingCandidates.isEmpty)
    var degreesOnly = AppearanceValues()
    degreesOnly.showDirection = false
    let custom = presentation(.usable, bearing: 180, appearance: degreesOnly)
    #expect(custom.bearing == "180°")
    #expect(custom.bearingCandidates == ["180°"])
    #expect(custom.spokenDescription.hasPrefix("180 degrees, south,"))
    var hidden = AppearanceValues()
    hidden.showDirection = false
    hidden.showDegrees = false
    #expect(presentation(.usable, bearing: 270, appearance: hidden).bearing == "W")
  }

  @Test func rejectedCourseClearsPreviouslyDeliveredActivityReading() async throws {
    let now = Date(timeIntervalSince1970: 100)
    for (source, reference, timestamp) in [
      (CompassSource.deviceHeading, NorthReference.trueNorth, now),
      (.vehicleCourse, .magnetic, now),
      (.vehicleCourse, .trueNorth, now.addingTimeInterval(1)),
    ] {
      let system = TestActivitySystem()
      let controller = CompassActivityController(system: system, now: { now })
      try await controller.start()
      let accepted = CompassSample(
        degrees: 90, source: .vehicleCourse, reference: .trueNorth,
        accuracy: 1, timestamp: now)
      await controller.update(.init(sample: accepted, status: .usable))
      #expect(system.handle.updates.last?.bearing == 90)
      let rejected = CompassSample(
        degrees: 42, source: source, reference: reference,
        accuracy: 1, timestamp: timestamp)
      await controller.update(.init(sample: rejected, status: .usable))
      let cleared = try #require(system.handle.updates.last)
      #expect(cleared.bearing == nil)
      #expect(cleared.status == .unavailable)
      await controller.end()
    }
  }

  @Test func explicitFailureClearsAndRecoveryRemainsRateLimited() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    func reading(_ degrees: Double) -> TravelPresentation {
      .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracy: 1, timestamp: time), status: .usable)
    }
    await controller.update(reading(42))
    let encoded = try JSONEncoder().encode(system.handle.updates[0])
    #expect(
      try JSONDecoder().decode(CompassActivityAttributes.ContentState.self, from: encoded)
        == system.handle.updates[0])
    time += 0.5
    await controller.update(reading(90))
    #expect(system.handle.updates.count == 1)
    await controller.invalidateReading()
    #expect(system.handle.updates.last?.bearing == nil)
    await controller.update(reading(90))
    #expect(system.handle.updates.last?.bearing == nil)
    time += 0.5
    await controller.update(reading(90))
    #expect(system.handle.updates.last?.bearing == 90)
    await controller.end()
    #expect(system.handle.finalState == .init(bearing: nil, status: .unavailable))
    let count = system.handle.updates.count
    await controller.update(reading(180))
    #expect(system.handle.updates.count == count)
  }

  @Test func startupInterruptionCannotClearTheNewReadingAfterRecovery() async throws {
    let system = TestActivitySystem()
    system.suspend = true
    let time = Date(timeIntervalSince1970: 100)
    let activity = CompassActivityController(system: system, now: { time })
    let sensor = TestTravelSensor()
    let drive = DriveSessionController(
      sensor: sensor, activity: activity,
      now: { time }, automaticTick: false)
    let startup = Task { await drive.carPlayActivated() }
    while system.resume == nil { await Task.yield() }
    sensor.receive?(.interrupted)
    sensor.receive?(
      .reading(
        TravelReading(
          course: 90, courseAccuracy: 1, speed: 10,
          speedAccuracy: 1, horizontalAccuracy: 5, timestamp: time)))
    system.resume?.resume()
    await startup.value
    await drive.waitForPendingOperations()
    #expect(system.handle.updates.last?.bearing == 90)
    await drive.endDrive()
  }

  @Test func secondInterruptionCannotRepublishReadingCapturedBeforeIt() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let sensor = TestTravelSensor()
    let activity = CompassActivityController(system: system, now: { time })
    let drive = DriveSessionController(
      sensor: sensor, activity: activity, now: { time }, automaticTick: false)
    await drive.carPlayActivated()
    func send(_ degrees: Double) {
      sensor.receive?(
        .reading(
          .init(
            course: degrees, courseAccuracy: 1, speed: 10, speedAccuracy: 1, horizontalAccuracy: 1,
            timestamp: time)))
    }
    send(42)
    await drive.waitForPendingOperations()
    time += 2
    system.handle.suspendNextUpdate = true
    sensor.receive?(.interrupted)
    send(90)
    while system.handle.resumeUpdate == nil { await Task.yield() }
    let countBeforeSecondInterruption = system.handle.updates.count
    sensor.receive?(.interrupted)
    system.handle.resumeUpdate?.resume()
    await drive.waitForPendingOperations()
    #expect(
      system.handle.updates.dropFirst(countBeforeSecondInterruption).allSatisfy {
        $0.bearing == nil
      })
    await drive.endDrive()
  }

  @Test func sampleAlreadyExpiredInDriveQueueDoesNotClearAcceptedReading() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    let first = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time)
    await controller.update(.init(sample: first, status: .usable))
    let delayed = CompassSample(
      degrees: 90, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: time + 1)
    time += 10
    await controller.update(.init(sample: delayed, status: .usable))
    #expect(system.handle.updates.map(\.bearing) == [42])
    #expect(system.handle.updates.last?.sampleTime == first?.timestamp)
    await controller.end()
  }

  @Test func sampleExpiringInQueueCannotReplaceTheLastAcceptedCourse() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    var evaluations = 0
    let controller = CompassActivityController(
      system: system,
      now: {
        evaluations += 1; return time
      })
    try await controller.start()
    func reading(_ degrees: Double) -> TravelPresentation {
      .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracy: 1, timestamp: time), status: .usable)
    }
    system.handle.suspendNextUpdate = true
    let first = reading(42)
    let writing = Task { await controller.update(first) }
    while system.handle.resumeUpdate == nil { await Task.yield() }
    time += 1
    let next = reading(90)
    let before = evaluations
    let queued = Task { await controller.update(next) }
    while evaluations == before { await Task.yield() }
    time += 60
    system.handle.resumeUpdate?.resume()
    await writing.value
    await queued.value
    #expect(system.handle.updates.map(\.bearing) == [42])
    #expect(system.handle.updates.last?.sampleTime == Date(timeIntervalSince1970: 100))
    await controller.update(reading(90))
    #expect(system.handle.updates.last?.bearing == 90)
    await controller.end()
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

@MainActor private final class TestTravelSensor: TravelLocationSensor {
  var authorization: TravelAuthorization = .authorized
  var fullAccuracy = true
  var servicesEnabled = true
  var available = true
  var receive: ((TravelSensorEvent) -> Void)?
  func requestAuthorization() {}
  func start() throws {}
  func stop() {}
}
