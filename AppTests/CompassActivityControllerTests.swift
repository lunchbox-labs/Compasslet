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
      accuracyDegrees: 1, timestamp: time)
    await controller.showAndWait(.init(sample: sample, status: .usable))
    let original = try #require(system.handle.updates.last)
    #expect(original.expiry == time.addingTimeInterval(CompassActivityController.staleInterval))
    for status in [TravelStatus.slow, .unreliable, .unavailable] {
      time += 60
      await controller.showAndWait(.init(sample: nil, status: status))
      #expect(system.handle.updates.last == original)
    }
    let next = CompassSample(
      degrees: 90, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time)
    await controller.showAndWait(.init(sample: next, status: .usable))
    #expect(system.handle.updates.last?.bearing == 90)
    #expect(system.handle.updates.last?.sampleTime == time)
    await controller.end().value
    try await controller.start()
    let count = system.handle.updates.count
    await controller.showAndWait(.init(sample: nil, status: .slow))
    #expect(system.handle.updates.count == count + 1)
    #expect(system.handle.updates.last?.bearing == nil)
    await controller.end().value
  }

  @Test func appearanceChangesKeepOriginalLastReadingTimestamp() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time)
    await controller.showAndWait(.init(sample: sample, status: .usable))
    let original = try #require(system.handle.updates.last)
    var appearance = AppearanceValues()
    appearance.showDegrees = false
    appearance.lockScreenTimestamp = .hidden
    appearance.carPlayActivityTimestamp = .elapsed
    time = time.addingTimeInterval(0.5)
    await controller.updateAppearance(appearance)?.value
    let changed = try #require(system.handle.updates.last)
    #expect(changed.bearing == original.bearing)
    #expect(changed.sampleTime == original.sampleTime)
    #expect(changed.expiry == time.addingTimeInterval(CompassActivityController.staleInterval))
    #expect(changed.appearance?.showDegrees == false)
    #expect(changed.appearance?.lockScreenTimestamp == .hidden)
    #expect(changed.appearance?.carPlayActivityTimestamp == .elapsed)
    time = time.addingTimeInterval(6)
    appearance.showDegrees = true
    await controller.updateAppearance(appearance)?.value
    #expect(system.handle.updates.last?.bearing == original.bearing)
    #expect(system.handle.updates.last?.sampleTime == original.sampleTime)
    #expect(
      system.handle.updates.last?.expiry
        == time.addingTimeInterval(CompassActivityController.staleInterval))
    await controller.end().value
    let count = system.handle.updates.count
    await controller.updateAppearance(appearance)?.value
    #expect(system.handle.updates.count == count)
  }

  @Test func appearancePreferenceChangesRewriteTheActivity() async throws {
    let name = "activity-appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults)
    let system = TestActivitySystem()
    let controller = CompassActivityController(system: system, appearanceStore: store)
    try await controller.start()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.isEmpty)
    // The observation delivers changes after the change itself, so wait for the rewrite.
    func waitForRewrite(after count: Int) async {
      let deadline = ContinuousClock.now + .seconds(5)
      while system.handle.updates.count <= count, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      await controller.waitForPendingOperations()
    }
    var values = AppearanceValues()
    values.showDegrees = false
    store.update { $0.setOverride(values, for: .activity) }
    await waitForRewrite(after: 0)
    #expect(system.handle.updates.count == 1)
    #expect(system.handle.updates.last?.appearance?.showDegrees == false)
    // A change that leaves the activity's appearance as it was doesn't rewrite it.
    store.update { $0.setOverride(values, for: .phone) }
    try await Task.sleep(for: .milliseconds(200))
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.count == 1)
    values.showDegrees = true
    store.update { $0.setOverride(values, for: .activity) }
    await waitForRewrite(after: 1)
    #expect(system.handle.updates.count == 2)
    #expect(system.handle.updates.last?.appearance?.showDegrees == true)
    await controller.end().value
  }

  @Test func aDroppedControllerStopsFollowingTheAppearance() async throws {
    let name = "activity-appearance-lifetime-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults)
    let system = TestActivitySystem()
    weak var dropped: CompassActivityController?
    do {
      let controller = CompassActivityController(system: system, appearanceStore: store)
      dropped = controller
      try await controller.start()
    }
    // The observation holds the controller weakly, so it goes once nothing else holds it. Wait
    // for that with a deadline rather than a fixed time, so a busy runner can't fail the test.
    let deadline = ContinuousClock.now + .seconds(5)
    while dropped != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(dropped == nil)
    var values = AppearanceValues()
    values.showDegrees = false
    store.update { $0.setOverride(values, for: .activity) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.handle.updates.isEmpty)
  }

  @Test func queuedAppearanceCannotRepublishAfterSensorInvalidation() async throws {
    let system = TestActivitySystem()
    let time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    system.handle.suspendNextUpdate = true
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time)
    controller.show(.init(sample: sample, status: .usable))
    while system.handle.resumeUpdate == nil { await Task.yield() }
    var appearance = AppearanceValues()
    appearance.showDegrees = false
    let cosmetic = controller.updateAppearance(appearance)
    controller.invalidateReading()
    system.handle.resumeUpdate?.resume()
    await cosmetic?.value
    await controller.waitForPendingOperations()
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
    await controller.end().value
    #expect(system.cleanups == 1)
    #expect(system.finalState == .init(bearing: nil, status: .unavailable))
    try await controller.start()
    try await controller.start()
    #expect(system.requests == 1)
    var dismissed = false
    controller.onDismiss = { dismissed = true }
    system.handle.onDismiss?()
    #expect(dismissed)
    await controller.showAndWait(.init(sample: nil, status: .waiting))
    #expect(system.handle.updates.isEmpty)
  }

  @Test func startAfterDismissalRequestsAFreshActivity() async throws {
    let system = TestActivitySystem()
    let controller = CompassActivityController(system: system)
    try await controller.start()
    let dismissed = system.handle
    await controller.showAndWait(.init(sample: nil, status: .unreliable))
    let delivered = dismissed.updates.count
    #expect(delivered > 0)
    dismissed.onDismiss?()
    let fresh = TestActivityHandle()
    system.handle = fresh
    try await controller.start()
    #expect(system.requests == 2)
    await controller.showAndWait(.init(sample: nil, status: .slow))
    #expect(fresh.updates.last?.status == .slow)
    #expect(dismissed.updates.count == delivered)
    await controller.end().value
    #expect(fresh.ends == 1)
  }

  @Test func cancelledStartupDisposesItsResult() async throws {
    let system = TestActivitySystem()
    system.suspend = true
    let controller = CompassActivityController(system: system)
    let startup = Task { try await controller.start() }
    while system.resume == nil { await Task.yield() }
    // The end joins the queue behind the request, which it overtakes.
    let ending = controller.end()
    system.resume?.resume()
    await #expect(throws: CompassActivityController.Failure.self) { try await startup.value }
    await ending.value
    #expect(system.handle.ends == 1)
    #expect(system.handle.finalState == .init(bearing: nil, status: .unavailable))
    #expect(system.cleanups == 1)
  }

  @Test func endBeforeAQueuedStartupRunsMeansNoRequest() async throws {
    let system = TestActivitySystem()
    system.suspendCleanup = true
    let controller = CompassActivityController(system: system)
    let cleanup = controller.end()
    let startup = Task { try await controller.start() }
    while system.resumeCleanup == nil { await Task.yield() }
    // The start joins the queue behind the suspended cleanup, and the end joins behind it.
    for _ in 0..<10 { await Task.yield() }
    let ending = controller.end()
    system.suspendCleanup = false
    system.resumeCleanup?.resume()
    await cleanup.value
    await #expect(throws: CompassActivityController.Failure.self) { try await startup.value }
    await ending.value
    #expect(system.requests == 0)
    #expect(system.handle.ends == 0)
    #expect(system.cleanups == 2)
  }

  @Test func startAfterAnEndRequestsOnlyOnceTheEndHasFinished() async throws {
    let system = TestActivitySystem()
    system.suspendCleanup = true
    let controller = CompassActivityController(system: system)
    let ending = controller.end()
    let startup = Task { try await controller.start() }
    while system.resumeCleanup == nil { await Task.yield() }
    for _ in 0..<10 { await Task.yield() }
    #expect(system.requests == 0)
    system.suspendCleanup = false
    system.resumeCleanup?.resume()
    await ending.value
    try await startup.value
    #expect(system.requests == 1)
    #expect(system.cleanups == 1)
    await controller.end().value
  }

  @Test func presentationsHandedOverDuringStartupAreWrittenOnceItShows() async throws {
    let system = TestActivitySystem()
    system.suspend = true
    let time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    let startup = Task { try await controller.start() }
    while system.resume == nil { await Task.yield() }
    controller.show(.init(sample: nil, status: .slow))
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time)
    controller.show(.init(sample: sample, status: .usable))
    #expect(system.handle.updates.isEmpty)
    system.resume?.resume()
    try await startup.value
    await controller.waitForPendingOperations()
    // Only the latest presentation is written.
    #expect(system.handle.updates.map(\.bearing) == [42])
    await controller.end().value
  }

  @Test func failedStartupDropsWhatWasHandedOver() async throws {
    let system = TestActivitySystem()
    system.fail = true
    let controller = CompassActivityController(system: system)
    controller.show(.init(sample: nil, status: .slow))
    await #expect(throws: CompassActivityController.Failure.self) { try await controller.start() }
    system.fail = false
    try await controller.start()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.isEmpty)
    await controller.end().value
  }

  @Test func clearDropsAPresentationHandedOverBeforeIt() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    func reading(_ degrees: Double) -> TravelPresentation {
      .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracyDegrees: 1, timestamp: time), status: .usable)
    }
    system.handle.suspendNextUpdate = true
    controller.show(reading(42))
    while system.handle.resumeUpdate == nil { await Task.yield() }
    time += 2
    controller.show(reading(90))
    controller.invalidateReading()
    system.handle.resumeUpdate?.resume()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42, nil])
    // A reading handed over after the clear is written.
    await controller.showAndWait(reading(90))
    #expect(system.handle.updates.map(\.bearing) == [42, nil, 90])
    await controller.end().value
  }

  @Test func everyWriteGoesStaleAfterTheStaleIntervalFromIt() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    let interval = CompassActivityController.staleInterval
    try await controller.start()
    #expect(system.requestedState?.expiry == time.addingTimeInterval(interval))
    for status in [TravelStatus.waiting, .slow, .unreliable, .unavailable] {
      time += 30
      await controller.showAndWait(.init(sample: nil, status: status))
      #expect(system.handle.updates.last?.expiry == time.addingTimeInterval(interval))
    }
    time += 30
    await controller.invalidateAndWait()
    #expect(system.handle.updates.last?.expiry == time.addingTimeInterval(interval))
    await controller.end().value
  }

  @Test func renewalKeepsARetainedReadingCurrentThroughALongStop() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    let interval = CompassActivityController.staleInterval
    try await controller.start()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time)
    await controller.showAndWait(.init(sample: sample, status: .usable))
    let original = try #require(system.handle.updates.last)
    // A stop: nothing new is written, so only renewal moves the stale date.
    time += 30
    await controller.showAndWait(.init(sample: nil, status: .slow))
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.count == 1)
    time += CompassActivityController.renewalInterval - 30
    controller.renew()
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.count == 2)
    let renewed = try #require(system.handle.updates.last)
    #expect(renewed.bearing == original.bearing)
    #expect(renewed.sampleTime == original.sampleTime)
    #expect(renewed.status == .usable)
    #expect(renewed.expiry == time.addingTimeInterval(interval))
    await controller.end().value
    time += CompassActivityController.renewalInterval
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.count == 2)
  }

  @Test func reportsActivitiesLeftFromAnEarlierLaunch() {
    let system = TestActivitySystem()
    let controller = CompassActivityController(system: system)
    #expect(!controller.hasActivities)
    system.hasActivities = true
    #expect(controller.hasActivities)
  }

  @Test func unchangedReadingsDoNotRenewTheRecordedSampleTime() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    // New accepted input remains fresh, but unchanged displayed directions aren't rewritten.
    for delivery in 0..<6 {
      time = Date(timeIntervalSince1970: 100 + Double(delivery))
      let sample = try #require(
        CompassSample(
          degrees: 270, source: .vehicleCourse, reference: .trueNorth,
          accuracyDegrees: 1, timestamp: time.addingTimeInterval(-1.5)))
      await controller.showAndWait(.init(sample: sample, status: .usable))
      #expect(
        system.handle.updates.last?.expiry
          == Date(timeIntervalSince1970: 100 + CompassActivityController.staleInterval))
      #expect(system.handle.updates.last?.sampleTime == Date(timeIntervalSince1970: 98.5))
    }
    #expect(system.handle.updates.count == 1)
    await controller.end().value
  }

  @Test func deliveredReadingsChangeAtRoundedDegreeBoundariesAndWrapNorth() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    for degrees in [22.1, 22.4, 22.5, 359.6, 0.2] {
      let sample = CompassSample(
        degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
        accuracyDegrees: 1, timestamp: time)
      await controller.showAndWait(.init(sample: sample, status: .usable))
      time += 1
    }
    #expect(system.handle.updates.map(\.bearing) == [22.1, 22.5, 359.6])
    #expect(
      system.handle.updates.map(\.sampleTime)
        == [100.0, 102, 103].map(Date.init(timeIntervalSince1970:)))
    await controller.end().value
  }

  @Test func readingsHandedOverDuringAWriteCompareWithTheLastWrittenDirection() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    func reading(_ degrees: Double) -> TravelPresentation {
      .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracyDegrees: 1, timestamp: time), status: .usable)
    }

    system.handle.suspendNextUpdate = true
    controller.show(reading(300))
    while system.handle.resumeUpdate == nil { await Task.yield() }
    time = time.addingTimeInterval(1)
    controller.show(reading(270))
    // The first write is still suspended, and only the latest reading waits behind it.
    #expect(system.handle.updates.map(\.bearing) == [300])
    system.handle.resumeUpdate?.resume()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [300, 270])
    time = time.addingTimeInterval(1)
    // The return to 300 differs from the 270 written last, so it isn't suppressed.
    await controller.showAndWait(reading(300))
    #expect(system.handle.updates.map(\.bearing) == [300, 270, 300])
    // Readings handed over during one write leave only the newest.
    system.handle.resumeUpdate = nil
    system.handle.suspendNextUpdate = true
    time = time.addingTimeInterval(1)
    controller.show(reading(10))
    while system.handle.resumeUpdate == nil { await Task.yield() }
    time = time.addingTimeInterval(1)
    for degrees in [20.0, 30, 40] { controller.show(reading(degrees)) }
    system.handle.resumeUpdate?.resume()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [300, 270, 300, 10, 40])
    await controller.end().value
  }

  /// ActivityKit keeps an activity's content as JSON, so an activity started before an update
  /// must still decode after it. These literals are the encoding before the status moved to
  /// CompassCore's `TravelStatus`.
  @Test func contentStateJSONStaysTheSame() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    func json(_ state: CompassActivityAttributes.ContentState) throws -> String {
      String(decoding: try encoder.encode(state), as: UTF8.self)
    }
    func decoded(_ json: String) throws -> CompassActivityAttributes.ContentState {
      try JSONDecoder().decode(CompassActivityAttributes.ContentState.self, from: Data(json.utf8))
    }
    let full = CompassActivityAttributes.ContentState(
      bearing: 42.5, status: .usable, sampleTime: Date(timeIntervalSinceReferenceDate: 100),
      expiry: Date(timeIntervalSinceReferenceDate: 400),
      debugUpdateTime: Date(timeIntervalSinceReferenceDate: 300))
    let fullJSON =
      #"{"bearing":42.5,"debugUpdateTime":300,"expiry":400,"sampleTime":100,"status":"usable"}"#
    #expect(try json(full) == fullJSON)
    #expect(try decoded(fullJSON) == full)
    let statuses: [(TravelStatus, String)] = [
      (.waiting, #"{"status":"waiting"}"#), (.usable, #"{"status":"usable"}"#),
      (.slow, #"{"status":"slow"}"#), (.unreliable, #"{"status":"unreliable"}"#),
      (.unavailable, #"{"status":"unavailable"}"#),
    ]
    for (status, expected) in statuses {
      let state = CompassActivityAttributes.ContentState(bearing: nil, status: status)
      #expect(try json(state) == expected)
      #expect(try decoded(expected) == state)
    }
  }

  @Test func activityReadingsSpeakOnlyShownReadingsAsRecordedTravel() {
    func presentation(
      _ status: TravelStatus, bearing: Double? = nil, isStale: Bool = false,
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
        == "45 degrees, northeast, last recorded travel direction")
    #expect(presentation(.usable, bearing: 359.6).bearing == "N 0°")
    // A stale payload, any non-usable status, or an out-of-range bearing is never spoken as a
    // recorded travel direction; each falls back to its spoken status.
    let withoutReading =
      [presentation(.usable, bearing: 45, isStale: true)]
      + [TravelStatus.waiting, .slow, .unreliable, .unavailable].map {
        presentation($0, bearing: 45)
      } + [Double.nan, .infinity, -1, 360].map { presentation(.usable, bearing: $0) }
    for value in withoutReading {
      #expect(value.reading == nil)
      #expect(value.bearing == "—")
      #expect(!value.spokenDescription.contains("last recorded"))
      #expect(value.spokenDescription == value.spokenStatus)
      #expect(value.compactBearing == "—")
    }
    #expect(
      presentation(.usable, bearing: 45, isStale: true).status == presentation(.unavailable).status)
    let statuses = [TravelStatus.waiting, .slow, .unreliable, .unavailable]
      .map { presentation($0).status }
    #expect(Set(statuses).count == statuses.count)
    let spoken = [TravelStatus.waiting, .slow, .unreliable, .unavailable]
      .map { presentation($0).spokenStatus }
    #expect(Set(spoken).count == spoken.count)
    // A status that isn't shortened is spoken as it shows.
    for value in [
      presentation(.waiting), presentation(.unavailable),
      presentation(.usable, bearing: 45, isStale: true),
    ] {
      #expect(value.spokenStatus == value.status)
    }
    // Shorter forms are offered only when both fields are shown, and never without a reading.
    #expect(usable.bearingCandidates == ["NE 45°", "45°", "NE"])
    var keepsDirection = AppearanceValues()
    keepsDirection.shortReadout = .direction
    #expect(
      presentation(.usable, bearing: 45, appearance: keepsDirection).bearingCandidates
        == ["NE 45°", "NE", "45°"])
    #expect(presentation(.waiting).bearingCandidates.isEmpty)
    #expect(presentation(.waiting).status == "Start moving")
    // The shortened statuses are spoken in full.
    #expect(presentation(.slow).status == "Keep moving")
    #expect(presentation(.slow).spokenDescription == "Keep moving to show travel direction")
    #expect(presentation(.unreliable).status == "Finding…")
    #expect(presentation(.unreliable).spokenDescription == "Finding travel direction")
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

  @Test func compactDynamicIslandShowsOneField() {
    func compact(_ appearance: AppearanceValues?, bearing: Double? = 45) -> String {
      CompassActivityReading(
        state: .init(
          bearing: bearing, status: bearing == nil ? .waiting : .usable, sampleTime: nil,
          expiry: nil, appearance: appearance),
        isStale: false
      ).compactBearing
    }
    // With both fields shown, it keeps the one When Only One Fits picks, degrees by default.
    #expect(compact(nil) == "45°")
    var keepsDirection = AppearanceValues()
    keepsDirection.shortReadout = .direction
    #expect(compact(keepsDirection) == "NE")
    // With one field shown, it shows that one whatever the setting says.
    var directionOnly = AppearanceValues()
    directionOnly.showDegrees = false
    #expect(compact(directionOnly) == "NE")
    var degreesOnly = keepsDirection
    degreesOnly.showDirection = false
    #expect(compact(degreesOnly) == "45°")
    #expect(compact(nil, bearing: nil) == "—")
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
        accuracyDegrees: 1, timestamp: now)
      await controller.showAndWait(.init(sample: accepted, status: .usable))
      #expect(system.handle.updates.last?.bearing == 90)
      let rejected = CompassSample(
        degrees: 42, source: source, reference: reference,
        accuracyDegrees: 1, timestamp: timestamp)
      await controller.showAndWait(.init(sample: rejected, status: .usable))
      let cleared = try #require(system.handle.updates.last)
      #expect(cleared.bearing == nil)
      #expect(cleared.status == .unavailable)
      await controller.end().value
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
          accuracyDegrees: 1, timestamp: time), status: .usable)
    }
    await controller.showAndWait(reading(42))
    let encoded = try JSONEncoder().encode(system.handle.updates[0])
    #expect(
      try JSONDecoder().decode(CompassActivityAttributes.ContentState.self, from: encoded)
        == system.handle.updates[0])
    time += 0.5
    await controller.showAndWait(reading(90))
    #expect(system.handle.updates.count == 1)
    await controller.invalidateAndWait()
    #expect(system.handle.updates.last?.bearing == nil)
    await controller.showAndWait(reading(90))
    #expect(system.handle.updates.last?.bearing == nil)
    time += 0.5
    await controller.showAndWait(reading(90))
    #expect(system.handle.updates.last?.bearing == 90)
    await controller.end().value
    #expect(system.handle.finalState == .init(bearing: nil, status: .unavailable))
    let count = system.handle.updates.count
    await controller.showAndWait(reading(180))
    #expect(system.handle.updates.count == count)
  }

  @Test func startupInterruptionCannotClearTheNewReadingAfterRecovery() async throws {
    let system = TestActivitySystem()
    system.suspend = true
    let clock = TestDriveClock(now: Date(timeIntervalSince1970: 100))
    let activity = CompassActivityController(system: system, now: { clock.now })
    let sensor = TestTravelSensor()
    let drive = DriveSessionController(sensor: sensor, activity: activity, clock: clock)
    let startup = Task { await drive.carPlayActivated() }
    while system.resume == nil { await Task.yield() }
    sensor.receive?(.interrupted)
    sensor.receive?(
      .reading(
        TravelReading(
          courseDegrees: 90, courseAccuracyDegrees: 1, speedMetersPerSecond: 10,
          speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 5, timestamp: clock.now)))
    system.resume?.resume()
    await startup.value
    await drive.waitForPendingOperations()
    // The clear from startup is written first, and the newer reading after it.
    #expect(system.handle.updates.map(\.bearing) == [nil, 90])
    await drive.endDrive()
  }

  @Test func secondInterruptionCannotRepublishReadingCapturedBeforeIt() async throws {
    let system = TestActivitySystem()
    let clock = TestDriveClock(now: Date(timeIntervalSince1970: 100))
    let sensor = TestTravelSensor()
    let activity = CompassActivityController(system: system, now: { clock.now })
    let drive = DriveSessionController(sensor: sensor, activity: activity, clock: clock)
    await drive.carPlayActivated()
    func send(_ degrees: Double) {
      sensor.receive?(
        .reading(
          .init(
            courseDegrees: degrees, courseAccuracyDegrees: 1, speedMetersPerSecond: 10,
            speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 1, timestamp: clock.now)))
    }
    send(42)
    await drive.waitForPendingOperations()
    clock.now += 2
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

  @Test func driveWritesOnlyTheLatestReadingAfterASuspendedWrite() async throws {
    let system = TestActivitySystem()
    let clock = TestDriveClock(now: Date(timeIntervalSince1970: 100))
    let sensor = TestTravelSensor()
    let activity = CompassActivityController(system: system, now: { clock.now })
    let drive = DriveSessionController(sensor: sensor, activity: activity, clock: clock)
    await drive.carPlayActivated()
    await drive.waitForPendingOperations()
    let initialCount = system.handle.updates.count
    func send(_ degrees: Double) {
      sensor.receive?(
        .reading(
          .init(
            courseDegrees: degrees, courseAccuracyDegrees: 1, speedMetersPerSecond: 10,
            speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 1, timestamp: clock.now)))
    }
    system.handle.suspendNextUpdate = true
    send(20)
    while system.handle.resumeUpdate == nil { await Task.yield() }
    for course in 30...100 { send(Double(course)) }
    sensor.receive?(.interrupted)
    system.handle.resumeUpdate?.resume()
    await drive.waitForPendingOperations()
    // The suspended reading, then the clear and the unavailable status; no later reading.
    let written = system.handle.updates.dropFirst(initialCount)
    #expect(written.map { $0.bearing == nil } == [false, true, true])
    #expect(written.last?.status == .unavailable)
    await drive.endDrive()
  }

  @Test func driveWritesTheClearThenOnlyTheLatestReadingAfterASuspendedWrite() async throws {
    let system = TestActivitySystem()
    let clock = TestDriveClock(now: Date(timeIntervalSince1970: 100))
    let sensor = TestTravelSensor()
    let activity = CompassActivityController(system: system, now: { clock.now })
    let drive = DriveSessionController(sensor: sensor, activity: activity, clock: clock)
    await drive.carPlayActivated()
    await drive.waitForPendingOperations()
    let initialCount = system.handle.updates.count
    func send(_ degrees: Double) {
      sensor.receive?(
        .reading(
          .init(
            courseDegrees: degrees, courseAccuracyDegrees: 1, speedMetersPerSecond: 10,
            speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 1, timestamp: clock.now)))
    }
    system.handle.suspendNextUpdate = true
    send(20)
    while system.handle.resumeUpdate == nil { await Task.yield() }
    sensor.receive?(.interrupted)
    // Past the rate limit, so a reading after the clear can be written.
    clock.now += 2
    for course in 30...100 { send(Double(course)) }
    system.handle.resumeUpdate?.resume()
    await drive.waitForPendingOperations()
    // The suspended reading, the clear, then only the latest reading handed over after it.
    let written = Array(system.handle.updates.dropFirst(initialCount))
    #expect(written.map { $0.bearing == nil } == [false, true, false])
    #expect(written[1].status == .unavailable)
    #expect(written.last?.bearing?.rounded() == 100)
    await drive.endDrive()
  }

  @Test func sampleAlreadyExpiredInDriveQueueDoesNotClearAcceptedReading() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    let first = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time)
    await controller.showAndWait(.init(sample: first, status: .usable))
    let delayed = CompassSample(
      degrees: 90, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time + 1)
    time += 10
    await controller.showAndWait(.init(sample: delayed, status: .usable))
    #expect(system.handle.updates.map(\.bearing) == [42])
    #expect(system.handle.updates.last?.sampleTime == first?.timestamp)
    await controller.end().value
  }

  @Test func sampleExpiringInQueueCannotReplaceTheLastAcceptedCourse() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    func reading(_ degrees: Double) -> TravelPresentation {
      .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracyDegrees: 1, timestamp: time), status: .usable)
    }
    system.handle.suspendNextUpdate = true
    controller.show(reading(42))
    while system.handle.resumeUpdate == nil { await Task.yield() }
    time += 1
    controller.show(reading(90))
    time += 60
    system.handle.resumeUpdate?.resume()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42])
    #expect(system.handle.updates.last?.sampleTime == Date(timeIntervalSince1970: 100))
    await controller.showAndWait(reading(90))
    #expect(system.handle.updates.last?.bearing == 90)
    await controller.end().value
  }

  @Test func theStandardUpdateFrequencyPassesOverAReadingThatComesTooSoon() async throws {
    let system = TestActivitySystem()
    var time = Date(timeIntervalSince1970: 100)
    let controller = CompassActivityController(system: system, now: { time })
    try await controller.start()
    await controller.showAndWait(travel(42, at: time))
    time += 0.5
    await controller.showAndWait(travel(90, at: time))
    // As before the update frequency setting: nothing holds the reading for a later write.
    time += 1
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42])
    await controller.end().value
  }

  @Test func aLowerUpdateFrequencyWritesTheNewestChangeOnceItsIntervalEnds() async throws {
    let system = TestActivitySystem()
    let start = Date(timeIntervalSince1970: 100)
    var time = start
    let controller = CompassActivityController(
      system: system, now: { time }, refreshInterval: { 15 })
    try await controller.start()
    await controller.showAndWait(travel(42, at: time))
    time = start + 1
    await controller.showAndWait(travel(90, at: time))
    time = start + 2
    await controller.showAndWait(travel(180, at: time))
    // The car stops: nothing usable follows, and the reading ages past its lifetime.
    time = start + 3
    await controller.showAndWait(.init(sample: nil, status: .slow))
    time = start + 14
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42])
    time = start + 15
    controller.renew()
    await controller.waitForPendingOperations()
    // Only the newest change is written, with the time it was recorded.
    #expect(system.handle.updates.map(\.bearing) == [42, 180])
    #expect(system.handle.updates.last?.sampleTime == start + 2)
    #expect(system.handle.updates.last?.status == .usable)
    #expect(
      system.handle.updates.last?.expiry
        == time.addingTimeInterval(CompassActivityController.staleInterval))
    // The write starts a new interval, and nothing is left to write at the next beat.
    time = start + 16
    await controller.showAndWait(travel(270, at: time))
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42, 180])
    time = start + 30
    await controller.showAndWait(travel(0, at: time))
    #expect(system.handle.updates.map(\.bearing) == [42, 180, 0])
    await controller.end().value
  }

  @Test func aHeldReadingGivesWayToTheShownDirectionOrAClear() async throws {
    let start = Date(timeIntervalSince1970: 100)
    for ending in ["return", "clear"] {
      let system = TestActivitySystem()
      var time = start
      let controller = CompassActivityController(
        system: system, now: { time }, refreshInterval: { 15 })
      try await controller.start()
      await controller.showAndWait(travel(42, at: time))
      time = start + 1
      await controller.showAndWait(travel(90, at: time))
      time = start + 2
      if ending == "return" {
        await controller.showAndWait(travel(42, at: time))
      } else {
        await controller.invalidateAndWait()
      }
      time = start + 15
      controller.renew()
      await controller.waitForPendingOperations()
      #expect(!system.handle.updates.contains { $0.bearing == 90 }, "\(ending)")
      await controller.end().value
    }
  }

  @Test func aHeldReadingRecordedTooLongAgoIsPassedOver() async throws {
    let system = TestActivitySystem()
    let start = Date(timeIntervalSince1970: 100)
    var time = start
    let controller = CompassActivityController(
      system: system, now: { time }, refreshInterval: { 15 })
    try await controller.start()
    await controller.showAndWait(travel(42, at: time))
    time = start + 1
    await controller.showAndWait(travel(90, at: time))
    // The renewal comes late, past the interval and a reading's lifetime after the sample.
    time = start + 1 + 15 + CompassSample.travelLifetime + 1
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42])
    // It is dropped rather than kept for a later beat.
    time += 1
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(!system.handle.updates.contains { $0.bearing == 90 })
    await controller.end().value
  }

  @Test func aLowerUpdateFrequencyShowsTheFirstDirectionAfterAClearAtOnce() async throws {
    let system = TestActivitySystem()
    let start = Date(timeIntervalSince1970: 100)
    var time = start
    let controller = CompassActivityController(
      system: system, now: { time }, refreshInterval: { 15 })
    try await controller.start()
    await controller.showAndWait(travel(42, at: time))
    time = start + 1
    await controller.invalidateAndWait()
    // Nothing is shown after the clear, so the next direction doesn't wait out the interval.
    time = start + 2
    await controller.showAndWait(travel(90, at: time))
    #expect(system.handle.updates.map(\.bearing) == [42, nil, 90])
    // The direction shown starts a new interval for the next change.
    time = start + 3
    await controller.showAndWait(travel(180, at: time))
    #expect(system.handle.updates.map(\.bearing) == [42, nil, 90])
    await controller.end().value
  }

  @Test func aUpdateFrequencyChangeAppliesToTheNextWrite() async throws {
    let system = TestActivitySystem()
    let start = Date(timeIntervalSince1970: 100)
    var time = start
    let settings = LiveActivitySettingsStore(defaults: nil)
    settings.update { $0.updateFrequency = .everyFifteenSeconds }
    let controller = CompassActivityController(
      system: system, now: { time },
      refreshInterval: { settings.preferences.updateFrequency.interval })
    try await controller.start()
    await controller.showAndWait(travel(42, at: time))
    time = start + 2
    await controller.showAndWait(travel(90, at: time))
    #expect(system.handle.updates.map(\.bearing) == [42])
    // Back to the standard rate: the held reading is written at the next beat.
    settings.update { $0.updateFrequency = .everySecond }
    time = start + 3
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42, 90])
    // A slower rate limits the next change from the last write.
    settings.update { $0.updateFrequency = .everyFiveSeconds }
    time = start + 6
    await controller.showAndWait(travel(180, at: time))
    #expect(system.handle.updates.map(\.bearing) == [42, 90])
    time = start + 8
    controller.renew()
    await controller.waitForPendingOperations()
    #expect(system.handle.updates.map(\.bearing) == [42, 90, 180])
    await controller.end().value
  }

  @Test func aDriveAtALowerUpdateFrequencyShowsTheTurnBeforeAStop() async throws {
    let system = TestActivitySystem()
    let clock = TestDriveClock(now: Date(timeIntervalSince1970: 100))
    let start = clock.now
    let sensor = TestTravelSensor()
    let activity = CompassActivityController(
      system: system, now: { clock.now }, refreshInterval: { 15 })
    let drive = DriveSessionController(sensor: sensor, activity: activity, clock: clock)
    await drive.carPlayActivated()
    func send(_ degrees: Double, speed: Double = 10) {
      sensor.receive?(
        .reading(
          .init(
            courseDegrees: degrees, courseAccuracyDegrees: 1, speedMetersPerSecond: speed,
            speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 1, timestamp: clock.now)))
    }
    send(42)
    await drive.waitForPendingOperations()
    clock.run(until: start + 1)
    send(90)
    await drive.waitForPendingOperations()
    clock.run(until: start + 2)
    send(90, speed: 0)
    await drive.waitForPendingOperations()
    #expect(system.handle.updates.compactMap(\.bearing) == [42])
    // The heartbeat writes the turn once the interval has passed, though the car has stopped.
    clock.run(until: start + 15.5)
    await drive.waitForPendingOperations()
    #expect(system.handle.updates.compactMap(\.bearing) == [42, 90])
    #expect(system.handle.updates.last?.sampleTime == start + 1)
    await drive.endDrive()
  }

}

/// A usable travel presentation recorded at `time`.
private func travel(_ degrees: Double, at time: Date) -> TravelPresentation {
  .init(
    sample: CompassSample(
      degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: time), status: .usable)
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
  var hasActivities = false
  var finalState: CompassActivityAttributes.ContentState?
  var handle = TestActivityHandle()
  var requestedState: CompassActivityAttributes.ContentState?
  func request(_ state: CompassActivityAttributes.ContentState) async throws
    -> any CompassActivityHandle
  {
    requests += 1
    requestedState = state
    if suspend { await withCheckedContinuation { resume = $0 } }
    if fail { throw CompassActivityController.Failure.unavailable }
    return handle
  }
  var suspendCleanup = false
  var resumeCleanup: CheckedContinuation<Void, Never>?
  func endSurvivors(_ finalState: CompassActivityAttributes.ContentState) async {
    self.finalState = finalState
    cleanups += 1
    if suspendCleanup { await withCheckedContinuation { resumeCleanup = $0 } }
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

extension CompassActivityController {
  /// Hands over a presentation and waits until it has been written or passed over.
  fileprivate func showAndWait(_ presentation: TravelPresentation) async {
    show(presentation)
    await waitForPendingOperations()
  }

  /// Clears the retained reading and waits until the clear has been written.
  fileprivate func invalidateAndWait() async {
    invalidateReading()
    await waitForPendingOperations()
  }
}
