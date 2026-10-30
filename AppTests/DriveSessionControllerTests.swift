import CompassCore
import XCTest
@testable import Compass

@MainActor
final class DriveSessionControllerTests: XCTestCase {
  final class Sensor: TravelLocationSensor {
    var authorization: TravelAuthorization = .authorized
    var fullAccuracy = true
    var servicesEnabled = true
    var available = true
    var receive: ((TravelSensorEvent) -> Void)?
    var starts = 0
    var stops = 0
    var requests = 0
    var fails = false
    func requestAuthorization() { requests += 1 }
    func start() throws {
      if fails { throw Failure.unavailable }
      starts += 1
    }
    func stop() { stops += 1 }
  }
  enum Failure: Error { case unavailable }
  final class Activity: CompassActivityPresenting {
    var onDismiss: (() -> Void)?
    var starts = 0
    var ends = 0
    var updates: [TravelPresentation] = []
    var fails = false
    var pauseStart = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var pauseUpdate = false
    var updateContinuation: CheckedContinuation<Void, Never>?
    var pauseEnd = false
    var endContinuation: CheckedContinuation<Void, Never>?
    func start() async throws {
      starts += 1
      if pauseStart {
        await withCheckedContinuation { startContinuation = $0 }
      }
      if fails { throw Failure.unavailable }
    }
    func update(_ presentation: TravelPresentation) async {
      updates.append(presentation)
      if pauseUpdate { await withCheckedContinuation { updateContinuation = $0 } }
    }
    func end() async {
      ends += 1
      if pauseEnd {
        await withCheckedContinuation { endContinuation = $0 }
      }
    }
  }
  var time = Date(timeIntervalSince1970: 1_000)
  func reading(_ course: Double = 90) -> TravelSensorEvent {
    .reading(
      TravelReading(
        course: course, courseAccuracy: 2, speed: 10,
        speedAccuracy: 1, horizontalAccuracy: 5, timestamp: time))
  }
  func make(_ sensor: Sensor, _ activity: Activity) -> DriveSessionController {
    DriveSessionController(
      sensor: sensor, activity: activity, now: { self.time }, automaticTick: false)
  }

  func testPhoneLaunchDoesNotAcquireAndPhoneRequestIsOnce() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    XCTAssertEqual(sensor.starts, 0)
    controller.requestPhoneAuthorization(isForeground: false)
    XCTAssertEqual(sensor.requests, 0)
    await controller.phoneBecameActive()
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 1)
    XCTAssertEqual(sensor.starts, 0)
    XCTAssertEqual(activity.starts, 0)
    sensor.authorization = .denied
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .denied)
    XCTAssertEqual(sensor.requests, 1)
  }

  func testForegroundRefreshReflectsSettingsWithoutStartingTravel() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .denied
    let controller = make(sensor, activity)
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .denied)
    sensor.authorization = .restricted
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .restricted)
    sensor.authorization = .authorized
    sensor.fullAccuracy = false
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .preciseLocationRequired)
    sensor.servicesEnabled = false
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .servicesDisabled)
    sensor.servicesEnabled = true
    sensor.fullAccuracy = true
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .ready)
    XCTAssertEqual(sensor.requests, 0)
    XCTAssertEqual(sensor.starts, 0)
    XCTAssertEqual(activity.starts, 0)
  }

  func testServicesDisabledOnReturnStopsActiveDriveAndClearsBearing() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    sensor.receive?(reading())
    sensor.servicesEnabled = false
    await controller.phoneBecameActive()
    await controller.waitForPendingOperations()
    XCTAssertEqual(controller.setupStatus, .servicesDisabled)
    XCTAssertFalse(controller.isDriving)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(activity.ends, 2)
    XCTAssertEqual(sensor.requests, 0)
  }

  func testPhoneForegroundCancelledDuringPreparationDoesNotPrompt() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    activity.pauseEnd = true
    let controller = make(sensor, activity)
    let opening = Task { await controller.phoneBecameActive() }
    while activity.endContinuation == nil { await Task.yield() }
    opening.cancel()
    activity.endContinuation?.resume()
    await opening.value
    XCTAssertEqual(sensor.requests, 0)
    XCTAssertEqual(sensor.starts, 0)
  }

  func testStartupReloadsWaitingAndHistoryClearsOnDeniedPermission() async {
    let sensor = Sensor(), activity = Activity()
    var snapshots: [LatestCourseSnapshot] = []
    var snapshot = LatestCourseSnapshot.unavailable(at: time)
    let controller = DriveSessionController(
      sensor: sensor, activity: activity, now: { self.time }, automaticTick: false,
      reloadWidget: { _ in snapshots.append(snapshot) }, writeWidget: { snapshot = $0 })
    await controller.carPlayActivated()
    XCTAssertEqual(snapshots.map(\.status), [.waiting])
    sensor.receive?(reading())
    let sampleTime = time
    time += 60
    controller.tick()
    XCTAssertEqual(snapshot.status, .historical)
    XCTAssertEqual(snapshot.sampleTime, sampleTime)
    XCTAssertEqual(snapshot.bearing, 90)
    XCTAssertNil(controller.presentation.sample)
    sensor.authorization = .denied
    sensor.receive?(.authorizationChanged)
    XCTAssertNil(snapshot.bearing)
    XCTAssertEqual(snapshot.status, .unavailable)
    XCTAssertFalse(controller.isDriving)
    await controller.waitForPendingOperations()
  }

  func testInterruptionClearsHistoricalFileBeforeNextReloadSlot() async {
    let sensor = Sensor(), activity = Activity()
    var snapshot = LatestCourseSnapshot.unavailable(at: time)
    let controller = DriveSessionController(
      sensor: sensor, activity: activity, now: { self.time }, automaticTick: false,
      writeWidget: { snapshot = $0 })
    await controller.carPlayActivated()
    sensor.receive?(reading())
    time += 6
    controller.tick()
    XCTAssertEqual(snapshot.status, .historical)
    time += 0.1
    sensor.receive?(.interrupted)
    XCTAssertNil(snapshot.bearing)
    await controller.endDrive()
  }

  func testAcquisitionDiagnosticsIdentifyStartAndTeardownReason() async {
    for reason in ["disconnect", "permission", "timeout", "dismissal"] {
      let sensor = Sensor(), activity = Activity()
      var events: [CompassDiagnostics.WidgetOutcome] = []
      let controller = DriveSessionController(
        sensor: sensor, activity: activity, now: { self.time }, automaticTick: false,
        diagnose: { _, outcome in events.append(outcome) })
      await controller.carPlayActivated()
      XCTAssertEqual(events, [.success])
      let expected: CompassDiagnostics.WidgetOutcome
      switch reason {
      case "disconnect":
        expected = .disconnected
        await controller.carPlayDisconnected()
      case "permission":
        expected = .permission
        sensor.authorization = .denied
        sensor.receive?(.authorizationChanged)
      case "timeout":
        expected = .timeout
        time += 8 * 60 * 60
        controller.tick()
      default:
        expected = .dismissed
        activity.onDismiss?()
      }
      XCTAssertEqual(events, [.success, expected])
      await controller.waitForPendingOperations()
    }
  }

  func testWidgetReloadsWaitAMinuteExceptWhenARecordedReadingIsCleared() async {
    let sensor = Sensor(), activity = Activity()
    var snapshot = LatestCourseSnapshot.unavailable(at: time)
    var reloaded: [LatestCourseSnapshot] = []
    let controller = DriveSessionController(
      sensor: sensor, activity: activity, now: { self.time }, automaticTick: false,
      reloadWidget: { _ in reloaded.append(snapshot) }, writeWidget: { snapshot = $0 })
    await controller.carPlayActivated()
    XCTAssertEqual(reloaded.count, 1)
    sensor.receive?(reading())
    XCTAssertEqual(reloaded.count, 2)
    XCTAssertEqual(reloaded.last?.bearing, 90)
    // Fresh readings keep the shared file current without spending budgeted reloads.
    for _ in 1...59 {
      time += 1
      sensor.receive?(reading())
      controller.tick()
      XCTAssertEqual(reloaded.count, 2)
      XCTAssertEqual(snapshot.sampleTime, time)
    }
    time += 1
    sensor.receive?(reading())
    XCTAssertEqual(reloaded.count, 3)
    XCTAssertEqual(reloaded.last?.bearing, 90)
    XCTAssertEqual(reloaded.last?.sampleTime, time)
    // Clearing a recorded reading reloads after ten seconds rather than waiting a minute.
    time += 10
    sensor.receive?(reading(-1))
    XCTAssertEqual(reloaded.count, 4)
    XCTAssertNil(reloaded.last?.bearing)
    XCTAssertEqual(reloaded.last?.status, .unreliable)
    time += 1
    sensor.receive?(reading())
    XCTAssertEqual(reloaded.count, 4)
    // Flapping accuracy writes the cleared file but cannot spend another reload yet.
    time += 1
    sensor.receive?(reading(-1))
    XCTAssertNil(snapshot.bearing)
    XCTAssertEqual(reloaded.count, 4)
    time += 1
    sensor.receive?(reading())
    XCTAssertEqual(reloaded.count, 4)
    time += 57
    sensor.receive?(reading())
    XCTAssertEqual(reloaded.count, 5)
    XCTAssertEqual(reloaded.last?.bearing, 90)
    await controller.endDrive()
    XCTAssertEqual(reloaded.count, 6)
    XCTAssertEqual(reloaded.last?.status, .unavailable)
  }

  func testWidgetInvalidationPrecedesReloadAndHistoryWaitsForTheNextSlot() async {
    let sensor = Sensor(), activity = Activity()
    var snapshot = LatestCourseSnapshot.unavailable(at: time)
    var displayed: [LatestCourseSnapshot] = []
    let controller = DriveSessionController(
      sensor: sensor, activity: activity, now: { self.time }, automaticTick: false,
      reloadWidget: { _ in displayed.append(snapshot) }, writeWidget: { snapshot = $0 })
    await controller.carPlayActivated()
    sensor.receive?(reading())
    XCTAssertEqual(displayed.last?.bearing, 90)
    XCTAssertEqual(displayed.count, 2)
    time += 10.5
    sensor.receive?(reading(-1))
    XCTAssertNil(snapshot.bearing)
    XCTAssertEqual(snapshot.status, .unreliable)
    XCTAssertEqual(displayed.count, 3)
    XCTAssertNil(displayed.last?.bearing)
    XCTAssertEqual(displayed.last?.status, .unreliable)
    time += 0.5
    sensor.receive?(reading(180))
    XCTAssertEqual(displayed.count, 3)
    time += 6
    controller.tick()
    XCTAssertEqual(snapshot.status, .historical)
    XCTAssertEqual(snapshot.bearing, 180)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertEqual(displayed.count, 3)
    time += 54
    controller.tick()
    XCTAssertEqual(displayed.count, 4)
    XCTAssertEqual(displayed.last?.bearing, 180)
    XCTAssertEqual(displayed.last?.status, .historical)
    await controller.endDrive()
    XCTAssertEqual(displayed.last?.status, .unavailable)
    XCTAssertNil(displayed.last?.bearing)
  }

  func testWidgetSnapshotRejectsHeadingMagneticAndFutureSamples() {
    for sample in [
      CompassSample(
        degrees: 90, source: .deviceHeading, reference: .trueNorth,
        accuracy: 1, timestamp: time),
      CompassSample(
        degrees: 90, source: .vehicleCourse, reference: .magnetic,
        accuracy: 1, timestamp: time),
      CompassSample(
        degrees: 90, source: .vehicleCourse, reference: .trueNorth,
        accuracy: 1, timestamp: time + 1),
    ] {
      let snapshot = DriveSessionController.widgetSnapshot(
        .init(sample: sample, status: .usable), now: time)
      XCTAssertNil(snapshot.bearing)
      XCTAssertEqual(snapshot.status, .unavailable)
    }
  }

  func testWidgetKeepsObservedSlowStateFreshWithoutInventingNewSamples() async {
    let sensor = Sensor(), activity = Activity()
    var snapshot = LatestCourseSnapshot.unavailable(at: time)
    let controller = DriveSessionController(
      sensor: sensor, activity: activity, now: { self.time }, automaticTick: false,
      writeWidget: { snapshot = $0 })
    await controller.carPlayActivated()
    for _ in 0..<10 {
      time += 1
      sensor.receive?(
        .reading(
          TravelReading(
            course: 90, courseAccuracy: 2, speed: 0, speedAccuracy: 1,
            horizontalAccuracy: 5, timestamp: time)))
      XCTAssertEqual(snapshot.status, .slow)
      XCTAssertEqual(snapshot.sampleTime, time)
      XCTAssertNil(snapshot.bearing)
    }
    let lastObservation = snapshot.sampleTime
    time += 1
    controller.tick()
    XCTAssertEqual(snapshot.sampleTime, lastObservation)
    time += 5
    controller.tick()
    XCTAssertEqual(snapshot.status, .unavailable)
    await controller.endDrive()
  }

  func testWidgetReloadEndsOnceAndIgnoresLateReadingsAfterDriveStops() async {
    for stop in ["end", "disconnect", "permission", "services"] {
      let sensor = Sensor(), activity = Activity()
      var reloads = 0
      var snapshot = LatestCourseSnapshot.unavailable(at: time)
      let controller = DriveSessionController(
        sensor: sensor, activity: activity, now: { self.time }, automaticTick: false,
        reloadWidget: { _ in
          reloads += 1
          if reloads == 3 { XCTAssertNil(snapshot.bearing) }
        }, writeWidget: { snapshot = $0 })
      await controller.carPlayActivated()
      let lateDelivery = sensor.receive
      sensor.receive?(reading())
      XCTAssertEqual(reloads, 2)
      switch stop {
      case "end": await controller.endDrive()
      case "disconnect": await controller.carPlayDisconnected()
      case "permission":
        sensor.authorization = .denied
        sensor.receive?(.authorizationChanged)
      default:
        sensor.available = false
        controller.tick()
      }
      XCTAssertFalse(controller.isDriving)
      XCTAssertEqual(snapshot.status, .unavailable)
      XCTAssertEqual(reloads, 3)
      time += 2
      lateDelivery?(reading())
      controller.tick()
      await controller.endDrive()
      XCTAssertEqual(reloads, 3)
      await controller.waitForPendingOperations()
    }
  }

  func testActivationStartsOnceAndResignationRetainsAcquisition() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 1)
    sensor.receive?(reading())
    XCTAssertEqual(controller.presentation.sample?.angle.degrees, 90)
    await controller.carPlayDisconnected()
    await controller.carPlayDisconnected()
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertFalse(controller.isDriving)
  }

  func testIneligibleAuthorizationAndPrecisionNeverAcquireOrPrompt() async {
    for (authorization, expected) in [
      (TravelAuthorization.notDetermined, DriveSessionController.SetupStatus.permissionRequired),
      (.denied, .denied), (.restricted, .restricted),
    ] {
      let sensor = Sensor(), activity = Activity()
      sensor.authorization = authorization
      let controller = make(sensor, activity)
      await controller.carPlayActivated()
      XCTAssertFalse(controller.isDriving)
      XCTAssertEqual(controller.setupStatus, expected)
      XCTAssertEqual(sensor.starts, 0)
      XCTAssertEqual(sensor.requests, 0)
    }
    let sensor = Sensor(), activity = Activity()
    sensor.fullAccuracy = false
    let controller = make(sensor, activity)
    await controller.carPlayActivated()
    XCTAssertEqual(controller.setupStatus, .preciseLocationRequired)
    XCTAssertEqual(sensor.starts, 0)
  }

  func testExplicitEndSuppressesDuplicateActivationUntilResignation() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    await controller.endDrive()
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 1)
    controller.carPlayResignedActive()
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 2)
  }

  func testEndDriveAfterResignationAllowsFirstExplicitReopen() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    await controller.endDrive()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    await controller.carPlayActivated()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 2)
    XCTAssertEqual(activity.starts, 2)
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 2)
  }

  func testActivityDismissalAfterResignationAllowsFirstExplicitReopen() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    activity.onDismiss?()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .dismissed)
    XCTAssertEqual(sensor.stops, 1)
    await controller.carPlayActivated()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 2)
    XCTAssertEqual(activity.starts, 2)
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 2)
  }

  func testOldCallbackCannotPublishIntoNextDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    let old = sensor.receive
    await controller.carPlayDisconnected()
    await controller.carPlayActivated()
    old?(reading(180))
    XCTAssertNil(controller.presentation.sample)
    sensor.receive?(reading(45))
    XCTAssertEqual(controller.presentation.sample?.angle.degrees, 45)
  }

  func testRevocationAndExpiryStopOnceAndClear() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    sensor.receive?(reading())
    sensor.authorization = .denied
    sensor.receive?(.authorizationChanged)
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertEqual(sensor.stops, 1)
    sensor.authorization = .authorized
    await controller.carPlayDisconnected()
    await controller.carPlayActivated()
    time = time.addingTimeInterval(8 * 60 * 60)
    controller.tick()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 2)
  }

  func testInterruptionFreshnessAndReversedTimestampResetBearing() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    sensor.receive?(reading(180))
    time = time.addingTimeInterval(-1)
    sensor.receive?(reading(30))
    XCTAssertEqual(controller.presentation.sample?.angle.degrees, 30)
    sensor.receive?(.interrupted)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertTrue(controller.isDriving)
    sensor.receive?(reading())
    time = time.addingTimeInterval(5.01)
    controller.tick()
    XCTAssertNil(controller.presentation.sample)
  }

  func testPrecisionLossAndDeniedDeliveryEndAcquisition() async {
    for losesPrecision in [true, false] {
      let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
      await controller.carPlayActivated()
      sensor.receive?(reading())
      if losesPrecision {
        sensor.fullAccuracy = false
        sensor.receive?(.authorizationChanged)
      } else {
        sensor.receive?(.authorizationLost)
      }
      await controller.waitForPendingOperations()
      XCTAssertFalse(controller.isDriving)
      XCTAssertNil(controller.presentation.sample)
      XCTAssertEqual(sensor.stops, 1)
    }
  }

  func testUnavailableAndBackgroundStartFailureDoNotCreateActivity() async {
    for available in [false, true] {
      let sensor = Sensor(), activity = Activity()
      sensor.available = available
      sensor.fails = true
      let controller = make(sensor, activity)
      await controller.carPlayActivated()
      XCTAssertFalse(controller.isDriving)
      XCTAssertEqual(controller.setupStatus, .unavailable)
      XCTAssertEqual(activity.starts, 0)
      XCTAssertEqual(sensor.stops, available ? 1 : 0)
    }
  }

  func testResignationDuringSurvivorCleanupDoesNotStartLocation() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    activity.pauseEnd = true
    let activation = Task { await controller.carPlayActivated() }
    while activity.endContinuation == nil { await Task.yield() }
    controller.carPlayResignedActive()
    activity.endContinuation?.resume()
    await activation.value
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.starts, 0)
  }

  func testDisconnectDuringActivityStartCannotAffectNewDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    activity.pauseStart = true
    let first = Task { await controller.carPlayActivated() }
    while activity.startContinuation == nil { await Task.yield() }
    let disconnect = Task { await controller.carPlayDisconnected() }
    while controller.isDriving { await Task.yield() }
    activity.pauseStart = false
    let next = Task { await controller.carPlayActivated() }
    while sensor.starts < 2 { await Task.yield() }
    activity.startContinuation?.resume()
    await first.value
    await disconnect.value
    await next.value
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(activity.ends, 2)
    sensor.receive?(reading(45))
    XCTAssertEqual(controller.presentation.sample?.angle.degrees, 45)
  }

  func testAuthorizationChangesRefreshPhoneSetupWithoutAcquisition() {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    sensor.authorization = .authorized
    sensor.receive?(.authorizationChanged)
    XCTAssertEqual(controller.setupStatus, .ready)
    XCTAssertEqual(sensor.starts, 0)
  }

  func testActivityDismissalStopsClearsAndSuppressesDuplicateActivation() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    sensor.receive?(reading())
    let oldReading = sensor.receive
    let oldDismissal = activity.onDismiss
    oldDismissal?()
    XCTAssertFalse(controller.isDriving)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertEqual(controller.compactStatus, .dismissed)
    XCTAssertEqual(sensor.stops, 1)
    oldReading?(reading(180))
    oldDismissal?()
    await controller.waitForPendingOperations()
    XCTAssertNil(controller.presentation.sample)
    XCTAssertEqual(activity.ends, 2)
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 1)
    controller.carPlayResignedActive()
    await controller.carPlayActivated()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(sensor.starts, 2)
    oldDismissal?()
    XCTAssertTrue(controller.isDriving)
  }

  func testDismissalDuringActivityStartupCannotPublishLaterActiveState() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    activity.pauseStart = true
    let activation = Task { await controller.carPlayActivated() }
    while activity.startContinuation == nil { await Task.yield() }
    sensor.receive?(reading())
    let oldReading = sensor.receive
    activity.onDismiss?()
    XCTAssertFalse(controller.isDriving)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertEqual(sensor.stops, 1)
    activity.startContinuation?.resume()
    await activation.value
    await controller.waitForPendingOperations()
    oldReading?(reading(180))
    XCTAssertEqual(controller.compactStatus, .dismissed)
    XCTAssertFalse(controller.isDriving)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertTrue(activity.updates.isEmpty)
    XCTAssertEqual(activity.ends, 2)
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 1)
  }

  func testSuspendedCompactWriteCoalescesToLatestInvalidation() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    let initialCount = activity.updates.count
    activity.pauseUpdate = true
    sensor.receive?(reading(20))
    while activity.updateContinuation == nil { await Task.yield() }
    for course in 30...100 { sensor.receive?(reading(Double(course))) }
    sensor.receive?(.interrupted)
    activity.pauseUpdate = false
    activity.updateContinuation?.resume()
    await controller.waitForPendingOperations()
    XCTAssertEqual(activity.updates.count, initialCount + 2)
    XCTAssertNil(activity.updates.last?.sample)
    XCTAssertEqual(activity.updates.last?.status, .unavailable)
    await controller.endDrive()
  }

  func testInitialSurvivorCleanupAndCompactFailureRetainFullscreen() async {
    let sensor = Sensor(), activity = Activity()
    activity.fails = true
    let controller = make(sensor, activity)
    await controller.prepare()
    await controller.prepare()
    XCTAssertEqual(activity.ends, 1)
    XCTAssertEqual(sensor.starts, 0)
    await controller.carPlayActivated()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .unavailable)
    sensor.receive?(reading())
    XCTAssertNotNil(controller.presentation.sample)
  }
}
