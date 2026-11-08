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
  /// Records what the drive hands to its Live Activity.
  final class Activity: CompassActivityPresenting {
    var onDismiss: (() -> Void)?
    var canStartActivities = true
    var hasActivities = false
    var starts = 0
    var renewals = 0
    func renew() { renewals += 1 }
    var invalidations = 0
    func invalidateReading() { invalidations += 1 }
    var ends = 0
    /// Every presentation handed over, in order.
    var updates: [TravelPresentation] = []
    var fails = false
    var pauseStart = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var pauseEnd = false
    var endContinuation: CheckedContinuation<Void, Never>?
    func start() async throws {
      starts += 1
      if pauseStart {
        await withCheckedContinuation { startContinuation = $0 }
      }
      if fails { throw Failure.unavailable }
    }
    func show(_ presentation: TravelPresentation) { updates.append(presentation) }
    func end() -> Task<Void, Never> {
      ends += 1
      guard pauseEnd else { return Task {} }
      return Task { await withCheckedContinuation { self.endContinuation = $0 } }
    }
    func waitForPendingOperations() async {}
  }
  let clock = TestDriveClock()
  var time: Date {
    get { clock.now }
    set { clock.now = newValue }
  }
  var carAudio = false
  var backgroundHolds = 0
  var backgroundReleases = 0
  func reading(_ course: Double = 90) -> TravelSensorEvent {
    .reading(
      TravelReading(
        courseDegrees: course, courseAccuracyDegrees: 2, speedMetersPerSecond: 10,
        speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 5, timestamp: time))
  }
  func make(_ sensor: Sensor, _ activity: Activity) -> DriveSessionController {
    DriveSessionController(
      sensor: sensor, activity: activity, clock: clock,
      carAudioRoute: { self.carAudio },
      backgroundTime: {
        self.backgroundHolds += 1
        return { self.backgroundReleases += 1 }
      })
  }
  /// Runs what has come due at the current time: the heartbeat once a second has passed since
  /// the last one, and any limit.
  func tick() { clock.fireDue() }
  func disconnectPastTheAbsenceLimit(_ controller: DriveSessionController) async {
    controller.carPlayDisconnected()
    time += DriveSessionController.carPlayAbsenceLimit + 1
    tick()
    await controller.waitForPendingOperations()
  }

  func testOnlyExplicitSensorInterruptionInvalidatesTheRetainedActivityReading() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    sensor.receive?(reading())
    await controller.waitForPendingOperations()
    time += 60
    tick()
    await controller.waitForPendingOperations()
    XCTAssertEqual(activity.invalidations, 0)
    sensor.receive?(.interrupted)
    await controller.waitForPendingOperations()
    XCTAssertEqual(activity.invalidations, 1)
    await controller.endDrive()
  }

  func testPhoneLaunchDoesNotAcquireAndAsksOnceWhileUndecided() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    XCTAssertEqual(sensor.starts, 0)
    controller.requestPhoneAuthorization(isForeground: false)
    XCTAssertEqual(sensor.requests, 0)
    // The prompt makes the app inactive and active again, which mustn't ask a second time.
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

  func testPermissionUndecidedAgainAfterAGrantAsksAgain() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 1)
    // Allow Once, which iOS later takes back.
    sensor.authorization = .authorized
    sensor.receive?(.authorizationChanged)
    XCTAssertEqual(controller.setupStatus, .ready)
    sensor.authorization = .notDetermined
    sensor.receive?(.authorizationChanged)
    XCTAssertEqual(controller.setupStatus, .permissionRequired)
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 2)
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 2)
  }

  func testPermissionUndecidedOnReturnAfterAGrantAsksAgain() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    await controller.phoneBecameActive()
    sensor.authorization = .authorized
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .ready)
    // The grant ends while the app is away, with no change reported before it returns.
    sensor.authorization = .notDetermined
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.setupStatus, .permissionRequired)
    XCTAssertEqual(sensor.requests, 2)
  }

  func testAskingFromSettingsWorksAfterAnEarlierUnansweredPrompt() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 1)
    // The prompt closed unanswered, so returning doesn't ask, but the user can.
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 1)
    controller.askForLocationPermission()
    XCTAssertEqual(sensor.requests, 2)
    sensor.authorization = .denied
    controller.askForLocationPermission()
    XCTAssertEqual(sensor.requests, 2)
  }

  func testAskingFromSettingsDoesNotAskAgainWhileThePromptShows() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    await controller.phoneBecameActive(requestingPermission: false)
    controller.askForLocationPermission()
    await controller.phoneBecameActive()
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 1)
  }

  func testPermissionUndecidedAgainDuringADriveAsksAgainOnReturn() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 1)
    sensor.authorization = .authorized
    sensor.receive?(.authorizationChanged)
    await controller.carPlayActivated()
    XCTAssertTrue(controller.isDriving)
    sensor.authorization = .notDetermined
    sensor.receive?(.authorizationChanged)
    XCTAssertFalse(controller.isDriving)
    await controller.waitForPendingOperations()
    await controller.phoneBecameActive()
    XCTAssertEqual(sensor.requests, 2)
  }

  func testPhoneActivationCanHoldTheLocationPromptUntilAsked() async {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    await controller.phoneBecameActive(requestingPermission: false)
    XCTAssertEqual(controller.setupStatus, .permissionRequired)
    XCTAssertEqual(sensor.requests, 0)
    controller.requestPhoneAuthorization(isForeground: true)
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
    controller.carPlayDisconnected()
    controller.carPlayDisconnected()
    XCTAssertTrue(controller.isDriving)
    time += DriveSessionController.carPlayAbsenceLimit + 1
    tick()
    tick()
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

  func testActivityDismissalAfterResignationKeepsDrivingUntilDisconnect() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    activity.onDismiss?()
    await controller.waitForPendingOperations()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .dismissed)
    XCTAssertEqual(sensor.stops, 0)
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 1)
    XCTAssertEqual(controller.compactStatus, .dismissed)
    await disconnectPastTheAbsenceLimit(controller)
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    await controller.carPlayActivated()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 2)
    XCTAssertEqual(activity.starts, 2)
  }

  func testOldCallbackCannotPublishIntoNextDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    let old = sensor.receive
    await disconnectPastTheAbsenceLimit(controller)
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
    controller.carPlayDisconnected()
    await controller.carPlayActivated()
    time = time.addingTimeInterval(8 * 60 * 60)
    tick()
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
    tick()
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
    controller.carPlayDisconnected()
    time += DriveSessionController.carPlayAbsenceLimit + 1
    tick()
    XCTAssertFalse(controller.isDriving)
    activity.pauseStart = false
    let next = Task { await controller.carPlayActivated() }
    while sensor.starts < 2 { await Task.yield() }
    activity.startContinuation?.resume()
    await first.value
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

  func testActivityDismissalKeepsDrivingWithoutCompactUpdates() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    sensor.receive?(reading())
    await controller.waitForPendingOperations()
    let delivered = activity.updates.count
    XCTAssertGreaterThan(delivered, 0)
    let oldDismissal = activity.onDismiss
    oldDismissal?()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.presentation.sample?.angle.degrees, 90)
    XCTAssertEqual(controller.compactStatus, .dismissed)
    XCTAssertEqual(sensor.stops, 0)
    time += 1
    sensor.receive?(reading(180))
    oldDismissal?()
    await controller.waitForPendingOperations()
    XCTAssertNotNil(controller.presentation.sample)
    XCTAssertEqual(activity.updates.count, delivered)
    XCTAssertEqual(activity.ends, 1)
    await controller.endDrive()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(activity.ends, 2)
    oldDismissal?()
    XCTAssertEqual(controller.compactStatus, .inactive)
  }

  func testDismissalDuringActivityStartupCannotPublishLaterActiveState() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    activity.pauseStart = true
    let activation = Task { await controller.carPlayActivated() }
    while activity.startContinuation == nil { await Task.yield() }
    sensor.receive?(reading())
    activity.onDismiss?()
    let handedOver = activity.updates.count
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .dismissed)
    XCTAssertEqual(sensor.stops, 0)
    activity.startContinuation?.resume()
    await activation.value
    await controller.waitForPendingOperations()
    time += 1
    sensor.receive?(reading(180))
    await controller.waitForPendingOperations()
    XCTAssertEqual(controller.compactStatus, .dismissed)
    XCTAssertTrue(controller.isDriving)
    XCTAssertNotNil(controller.presentation.sample)
    // Nothing reaches the activity after its dismissal.
    XCTAssertEqual(activity.updates.count, handedOver)
    XCTAssertEqual(activity.ends, 1)
    await disconnectPastTheAbsenceLimit(controller)
    XCTAssertEqual(activity.ends, 2)
  }

  func testManualStartWithCarPlayConnectedRunsUntilTheUserEndsIt() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    controller.carPlayConnected()
    await controller.startLiveActivity()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 1)
    sensor.receive?(reading(45))
    await controller.waitForPendingOperations()
    XCTAssertEqual(activity.updates.last?.sample?.angle.degrees, 45)
    await controller.startLiveActivity()
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 1)
    time += 10 * 60
    tick()
    XCTAssertTrue(controller.isDriving)
    await controller.endLiveActivity()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .inactive)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(activity.ends, 2)
  }

  func testStartBeforeCarPlayConnectsEndsAfterTheAbsenceLimit() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    time += DriveSessionController.carPlayAbsenceLimit
    tick()
    XCTAssertTrue(controller.isDriving)
    time += 1
    tick()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .inactive)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(activity.ends, 2)
  }

  func testCarPlayConnectingWithinTheLimitKeepsAnEarlierStart() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    time += DriveSessionController.carPlayAbsenceLimit - 1
    controller.carPlayConnected()
    time += 10 * 60
    tick()
    XCTAssertTrue(controller.isDriving)
    await controller.carPlayActivated()
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 1)
    XCTAssertEqual(controller.compactStatus, .active)
    await controller.endDrive()
  }

  func testReconnectingWithinTheLimitKeepsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    controller.carPlayDisconnected()
    XCTAssertFalse(controller.isCarPlayConnected)
    time += 30
    tick()
    XCTAssertTrue(controller.isDriving)
    controller.carPlayConnected()
    XCTAssertTrue(controller.isCarPlayConnected)
    time += DriveSessionController.carPlayAbsenceLimit
    tick()
    XCTAssertTrue(controller.isDriving)
    controller.carPlayDisconnected()
    time += DriveSessionController.carPlayAbsenceLimit
    tick()
    XCTAssertTrue(controller.isDriving)
    time += 1
    tick()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(sensor.stops, 1)
  }

  /// Changes the car audio route and delivers its notification.
  func setCarAudio(_ connected: Bool, _ controller: DriveSessionController) {
    carAudio = connected
    controller.carAudioChanged(connected: connected)
  }

  func testCarAudioKeepsAShortcutStartWithoutTheCarPlayScreen() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    XCTAssertTrue(controller.isDriving)
    XCTAssertFalse(controller.isCarPlayConnected)
    time += 10 * 60
    tick()
    XCTAssertTrue(controller.isDriving)
    setCarAudio(false, controller)
    time += DriveSessionController.carPlayAbsenceLimit
    tick()
    XCTAssertTrue(controller.isDriving)
    time += 1
    tick()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(activity.ends, 2)
  }

  func testCarAudioConnectingWithinTheLimitKeepsAnEarlierStart() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    time += DriveSessionController.carPlayAbsenceLimit - 1
    setCarAudio(true, controller)
    time += 10 * 60
    tick()
    XCTAssertTrue(controller.isDriving)
    await controller.endDrive()
  }

  func testStartReadsTheCarAudioRouteWithoutANotification() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    carAudio = true
    await controller.startLiveActivity()
    XCTAssertTrue(controller.isCarAudioConnected)
    time += 10 * 60
    tick()
    XCTAssertTrue(controller.isDriving)
    await controller.endDrive()
  }

  func testTickNoticesAMissedCarAudioChange() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    carAudio = false
    time += DriveSessionController.heartbeatInterval
    tick()
    XCTAssertFalse(controller.isCarAudioConnected)
    XCTAssertTrue(controller.isDriving)
    time += DriveSessionController.carPlayAbsenceLimit + 1
    tick()
    XCTAssertFalse(controller.isDriving)
  }

  func testCarPlayScreenDisconnectKeepsTheDriveWhileCarAudioRemains() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    controller.carPlayDisconnected()
    time += 10 * 60
    tick()
    XCTAssertTrue(controller.isDriving)
    setCarAudio(false, controller)
    time += DriveSessionController.carPlayAbsenceLimit + 1
    tick()
    XCTAssertFalse(controller.isDriving)
  }

  func testCarAudioLossDuringACarPlayScreenDriveKeepsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.carPlayActivated()
    setCarAudio(false, controller)
    time += 10 * 60
    tick()
    XCTAssertTrue(controller.isDriving)
    await disconnectPastTheAbsenceLimit(controller)
    XCTAssertFalse(controller.isDriving)
  }

  func testFirstReadingIsRecordedPerDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    XCTAssertFalse(controller.hasReceivedReading)
    sensor.receive?(reading())
    XCTAssertTrue(controller.hasReceivedReading)
    await controller.endDrive()
    XCTAssertFalse(controller.hasReceivedReading)
    await controller.startLiveActivity()
    XCTAssertFalse(controller.hasReceivedReading)
    await controller.endDrive()
  }

  func testBackgroundStartWithoutAReadingNeedsTheForeground() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    let needed = await controller.needsForegroundStart(waitingUpTo: .milliseconds(300))
    XCTAssertTrue(needed)
    await controller.endDrive()
  }

  func testLocationNotInUseNeedsTheForegroundEvenAfterAReading() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    sensor.receive?(reading())
    sensor.receive?(.notInUse)
    let needed = await controller.needsForegroundStart(waitingUpTo: .seconds(5))
    XCTAssertTrue(needed)
    await controller.endDrive()
    XCTAssertFalse(controller.locationNeedsForeground)
  }

  func testLateNotInUseWithoutLaterReadingsEndsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    sensor.receive?(reading())
    let needed = await controller.needsForegroundStart(waitingUpTo: .milliseconds(300))
    XCTAssertFalse(needed)
    sensor.receive?(.notInUse)
    sensor.receive?(.notInUse)
    XCTAssertEqual(backgroundHolds, 1)
    time += DriveSessionController.notInUseLimit
    tick()
    XCTAssertTrue(controller.isDriving)
    time += 1
    activity.pauseEnd = true
    tick()
    XCTAssertFalse(controller.isDriving)
    while activity.endContinuation == nil { await Task.yield() }
    // The background time lasts until the Live Activity has ended.
    XCTAssertEqual(backgroundReleases, 0)
    activity.endContinuation?.resume()
    await controller.waitForPendingOperations()
    XCTAssertEqual(activity.ends, 2)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(backgroundReleases, 1)
  }

  func testReadingTakenBeforeTheNotInUseReportStillEndsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    let earlier = reading()
    time += 1
    sensor.receive?(.notInUse)
    sensor.receive?(earlier)
    XCTAssertEqual(backgroundReleases, 0)
    time += DriveSessionController.notInUseLimit + 1
    tick()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(backgroundReleases, 1)
  }

  func testLateNotInUseFollowedByReadingsKeepsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    sensor.receive?(reading())
    sensor.receive?(.notInUse)
    time += 1
    sensor.receive?(reading())
    XCTAssertEqual(backgroundReleases, 1)
    time += DriveSessionController.notInUseLimit + 1
    sensor.receive?(reading())
    tick()
    XCTAssertTrue(controller.isDriving)
    // A later report waits again, and ending the drive gives the background time back.
    sensor.receive?(.notInUse)
    XCTAssertEqual(backgroundHolds, 2)
    await controller.endDrive()
    XCTAssertEqual(backgroundReleases, 2)
  }

  func testNotInUseDuringACarPlaySceneDriveKeepsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    sensor.receive?(.notInUse)
    time += DriveSessionController.notInUseLimit + 1
    tick()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(backgroundHolds, 0)
    await controller.endDrive()
  }

  func testNotInUseBeforeTheCarPlaySceneOpensKeepsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    sensor.receive?(.notInUse)
    await controller.carPlayActivated()
    XCTAssertEqual(backgroundReleases, 1)
    time += DriveSessionController.notInUseLimit + 1
    tick()
    XCTAssertTrue(controller.isDriving)
    await controller.endDrive()
  }

  func testBackgroundStartWithAReadingStaysInTheBackground() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    await controller.startLiveActivity()
    sensor.receive?(reading())
    let needed = await controller.needsForegroundStart(waitingUpTo: .milliseconds(300))
    XCTAssertFalse(needed)
    XCTAssertTrue(controller.isDriving)
    await controller.endDrive()
  }

  func testDriveEndedDuringTheWaitNeverNeedsTheForeground() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    Task { await controller.endLiveActivity() }
    let needed = await controller.needsForegroundStart(waitingUpTo: .seconds(5))
    XCTAssertFalse(needed)
    XCTAssertFalse(controller.isDriving)
  }

  func testCarPlaySceneDriveNeverNeedsTheForeground() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    let needed = await controller.needsForegroundStart(waitingUpTo: .milliseconds(300))
    XCTAssertFalse(needed)
    await controller.endDrive()
  }

  func testManualStartNeedsReadyLocation() async {
    let sensor = Sensor(), activity = Activity()
    sensor.fullAccuracy = false
    let controller = make(sensor, activity)
    controller.carPlayConnected()
    await controller.startLiveActivity()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.setupStatus, .preciseLocationRequired)
    XCTAssertEqual(sensor.starts, 0)
    XCTAssertEqual(activity.starts, 0)
  }

  func testManualStartRestartsOnlyADismissedActivityDuringACarPlayDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    activity.onDismiss?()
    XCTAssertEqual(controller.compactStatus, .dismissed)
    sensor.receive?(.interrupted)
    time += 1
    sensor.receive?(reading(180))
    await controller.waitForPendingOperations()
    let delivered = activity.updates.count
    await controller.startLiveActivity()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 2)
    XCTAssertEqual(activity.invalidations, 0)
    XCTAssertEqual(activity.updates.count, delivered + 1)
    XCTAssertEqual(activity.updates.last?.sample?.angle.degrees, 180)
    activity.onDismiss?()
    XCTAssertEqual(controller.compactStatus, .dismissed)
    await disconnectPastTheAbsenceLimit(controller)
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 1)
  }

  func testManualStartRetriesAnActivityThatCouldNotStart() async {
    let sensor = Sensor(), activity = Activity()
    activity.fails = true
    let controller = make(sensor, activity)
    await controller.carPlayActivated()
    XCTAssertEqual(controller.compactStatus, .unavailable)
    await controller.startLiveActivity()
    XCTAssertEqual(controller.compactStatus, .unavailable)
    activity.fails = false
    await controller.startLiveActivity()
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 3)
  }

  func testManualEndDuringCarPlaySuppressesReactivationButAllowsManualStart() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    await controller.endLiveActivity()
    await controller.carPlayActivated()
    XCTAssertFalse(controller.isDriving)
    await controller.startLiveActivity()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 2)
    XCTAssertEqual(activity.starts, 2)
  }

  func testDismissingTheActivityWithoutCarPlayEndsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    activity.onDismiss?()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .inactive)
    XCTAssertEqual(sensor.stops, 1)
    XCTAssertEqual(activity.ends, 2)
    await controller.carPlayActivated()
    controller.carPlayDisconnected()
    activity.onDismiss?()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 2)
  }

  func testStartWithoutCarPlayAndLiveActivitiesOffNeverAcquiresLocation() async {
    let sensor = Sensor(), activity = Activity()
    activity.canStartActivities = false
    let controller = make(sensor, activity)
    await controller.startLiveActivity()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .unavailable)
    XCTAssertEqual(sensor.starts, 0)
    XCTAssertEqual(activity.starts, 0)
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.compactStatus, .unavailable)
    activity.canStartActivities = true
    await controller.phoneBecameActive()
    XCTAssertEqual(controller.compactStatus, .inactive)
    await controller.startLiveActivity()
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .active)
  }

  func testActivityFailureWithoutCarPlayEndsTheDrive() async {
    let sensor = Sensor(), activity = Activity()
    activity.fails = true
    let controller = make(sensor, activity)
    await controller.startLiveActivity()
    await controller.waitForPendingOperations()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .unavailable)
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(sensor.stops, 1)
  }

  func testEndLiveActivityWithoutADriveEndsAnActivityLeftFromEarlier() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.endLiveActivity()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(activity.ends, 1)
    XCTAssertEqual(sensor.starts, 0)
  }

  func testHeartbeatRenewsOnlyAShowingActivity() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    let beat = DriveSessionController.heartbeatInterval
    time += beat
    tick()
    XCTAssertEqual(activity.renewals, 0)
    await controller.carPlayActivated()
    XCTAssertEqual(controller.compactStatus, .active)
    // The heartbeat waits a full interval after the drive starts.
    tick()
    XCTAssertEqual(activity.renewals, 0)
    time += beat
    tick()
    XCTAssertEqual(activity.renewals, 1)
    activity.onDismiss?()
    XCTAssertEqual(controller.compactStatus, .dismissed)
    time += beat
    tick()
    XCTAssertEqual(activity.renewals, 1)
    await controller.endDrive()
    time += beat
    tick()
    XCTAssertEqual(activity.renewals, 1)
  }

  func testReportsALiveActivityLeftFromAnEarlierLaunch() {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    XCTAssertFalse(controller.hasLiveActivity)
    activity.hasActivities = true
    XCTAssertTrue(controller.hasLiveActivity)
  }

  func testEndingDuringAnActivityRestartLeavesTheDriveEnded() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    activity.onDismiss?()
    activity.pauseStart = true
    let restart = Task { await controller.startLiveActivity() }
    while activity.startContinuation == nil { await Task.yield() }
    let ending = Task { await controller.endDrive() }
    while controller.isDriving { await Task.yield() }
    activity.startContinuation?.resume()
    await restart.value
    await ending.value
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.compactStatus, .inactive)
    XCTAssertEqual(activity.starts, 2)
    XCTAssertEqual(activity.ends, 2)
  }

  func testRepeatedStartsDuringActivityStartupStartOnce() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    activity.pauseStart = true
    let first = Task { await controller.startLiveActivity() }
    while activity.startContinuation == nil { await Task.yield() }
    await controller.startLiveActivity()
    await controller.carPlayActivated()
    XCTAssertEqual(controller.compactStatus, .starting)
    activity.startContinuation?.resume()
    await first.value
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertEqual(sensor.starts, 1)
    XCTAssertEqual(activity.starts, 1)
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

  func testTheAbsenceLimitEndsTheDriveOnTimeBetweenHeartbeats() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    let start = time
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    clock.run(until: start + 0.5)
    controller.carPlayDisconnected()
    clock.run(until: start + 0.5 + DriveSessionController.carPlayAbsenceLimit)
    XCTAssertTrue(controller.isDriving)
    // The next heartbeat is half a second away, so only the limit's own deadline ends it.
    clock.run(until: start + 0.6 + DriveSessionController.carPlayAbsenceLimit)
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    await controller.waitForPendingOperations()
    XCTAssertEqual(activity.ends, 2)
  }

  func testTheNotInUseLimitEndsTheDriveOnTimeBetweenHeartbeats() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    let start = time
    await controller.startLiveActivity()
    clock.run(until: start + 0.5)
    sensor.receive?(.notInUse)
    clock.run(until: start + 0.5 + DriveSessionController.notInUseLimit)
    XCTAssertTrue(controller.isDriving)
    clock.run(until: start + 0.6 + DriveSessionController.notInUseLimit)
    XCTAssertFalse(controller.isDriving)
    await controller.waitForPendingOperations()
    XCTAssertEqual(backgroundReleases, 1)
  }

  func testAReadingExpiresOnTimeBetweenHeartbeats() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    let start = time
    await controller.carPlayActivated()
    clock.run(until: start + 0.5)
    sensor.receive?(reading())
    clock.run(until: start + 0.5 + DriveSessionController.readingLifetime)
    XCTAssertNotNil(controller.presentation.sample)
    clock.run(until: start + 0.6 + DriveSessionController.readingLifetime)
    XCTAssertNil(controller.presentation.sample)
    XCTAssertEqual(controller.presentation.status, .unavailable)
    XCTAssertNil(activity.updates.last?.sample)
    XCTAssertTrue(controller.isDriving)
    await controller.endDrive()
  }

  func testEachNewReadingMovesTheExpiryLater() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    let start = time
    await controller.carPlayActivated()
    sensor.receive?(reading(10))
    // A newer reading arrives before the first expires, so travel stays current past it.
    clock.run(until: start + 4)
    sensor.receive?(reading(20))
    clock.run(until: start + 8)
    XCTAssertNotNil(controller.presentation.sample)
    // The deadline comes first and only then a reading, which shows travel again.
    clock.run(until: start + 9.5)
    XCTAssertNil(controller.presentation.sample)
    sensor.receive?(reading(30))
    XCTAssertNotNil(controller.presentation.sample)
    await controller.endDrive()
  }

  func testViewsSeeTheLiveActivityStatusButNotAnUnchangedSetup() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.carPlayActivated()
    // Each reading refreshes the setup, but only a change to it reaches the phone's screen.
    XCTAssertFalse(notifies({ _ = controller.setupStatus }, when: { sensor.receive?(reading(10)) }))
    XCTAssertTrue(notifies({ _ = controller.presentation }, when: { sensor.receive?(reading(20)) }))
    // The status lives on the drive's session, and views still see it change.
    XCTAssertTrue(controller.isLiveActivityRunning)
    XCTAssertTrue(
      notifies({ _ = controller.isLiveActivityRunning }, when: { activity.onDismiss?() }))
    XCTAssertFalse(controller.isLiveActivityRunning)
    XCTAssertTrue(controller.isDriving)
    await controller.endDrive()
  }

  func testTheHeartbeatBeatsOnceASecondAndStopsWithTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    let start = time
    XCTAssertTrue(clock.pending.isEmpty)
    await controller.carPlayActivated()
    clock.run(until: start + 10.5)
    XCTAssertEqual(activity.renewals, 10)
    await controller.endDrive()
    // The ended drive leaves no heartbeat or deadline behind.
    XCTAssertTrue(clock.pending.isEmpty)
    clock.run(until: start + 20)
    XCTAssertEqual(activity.renewals, 10)
  }

  func testALateHeartbeatSetsTheNextOneAnIntervalAfterItRan() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    let start = time
    await controller.carPlayActivated()
    XCTAssertEqual(clock.pending, [start + 1])
    // A beat that wakes late sets the next one a full interval after it ran.
    time = start + 1.4
    tick()
    XCTAssertEqual(activity.renewals, 1)
    XCTAssertEqual(clock.pending, [time.addingTimeInterval(1)])
    // A wake that misses several intervals beats once, with no burst to catch up.
    time = start + 5.5
    tick()
    XCTAssertEqual(activity.renewals, 2)
    XCTAssertEqual(clock.pending, [time.addingTimeInterval(1)])
    await controller.endDrive()
  }

  func testReconnectingAsTheAbsenceLimitComesKeepsTheDrive() async {
    for carAudioReturns in [false, true] {
      let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
      let start = time
      await controller.carPlayActivated()
      controller.carPlayResignedActive()
      controller.carPlayDisconnected()
      clock.run(until: start + DriveSessionController.carPlayAbsenceLimit)
      // The car returns just before the deadline fires.
      if carAudioReturns {
        setCarAudio(true, controller)
      } else {
        controller.carPlayConnected()
      }
      clock.run(until: start + 2 * DriveSessionController.carPlayAbsenceLimit)
      XCTAssertTrue(controller.isDriving)
      XCTAssertEqual(sensor.stops, 0)
      await controller.endDrive()
      setCarAudio(false, controller)
    }
  }

  func testNotInUseClearedByCarPlayAsItsLimitComesKeepsTheDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    setCarAudio(true, controller)
    let start = time
    await controller.startLiveActivity()
    sensor.receive?(.notInUse)
    clock.run(until: start + DriveSessionController.notInUseLimit)
    await controller.carPlayActivated()
    controller.carPlayResignedActive()
    clock.run(until: start + 2 * DriveSessionController.notInUseLimit)
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(backgroundReleases, 1)
    await controller.endDrive()
  }

  func testATimerFromAnEndedDriveCannotEndTheNextDrive() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    let start = time
    // The first drive starts without the car, so its absence deadline is set.
    await controller.startLiveActivity()
    await controller.endDrive()
    controller.carPlayConnected()
    await controller.startLiveActivity()
    clock.run(until: start + 2 * DriveSessionController.carPlayAbsenceLimit)
    XCTAssertTrue(controller.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    await controller.endDrive()
  }

  func testLiveActivityRunningFollowsTheDrivesActivity() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    XCTAssertFalse(controller.isLiveActivityRunning)
    activity.pauseStart = true
    let starting = Task { await controller.carPlayActivated() }
    while activity.startContinuation == nil { await Task.yield() }
    XCTAssertEqual(controller.compactStatus, .starting)
    XCTAssertTrue(controller.isLiveActivityRunning)
    activity.startContinuation?.resume()
    await starting.value
    XCTAssertEqual(controller.compactStatus, .active)
    XCTAssertTrue(controller.isLiveActivityRunning)
    activity.onDismiss?()
    XCTAssertTrue(controller.isDriving)
    XCTAssertFalse(controller.isLiveActivityRunning)
    activity.pauseStart = false
    activity.fails = true
    await controller.startLiveActivity()
    XCTAssertEqual(controller.compactStatus, .unavailable)
    XCTAssertTrue(controller.isDriving)
    XCTAssertFalse(controller.isLiveActivityRunning)
    await controller.endDrive()
    XCTAssertFalse(controller.isLiveActivityRunning)
    XCTAssertEqual(controller.compactStatus, .inactive)
  }

  func testLocationStartFailureLeavesNoLiveActivityState() async {
    let sensor = Sensor(), activity = Activity()
    activity.fails = true
    let controller = make(sensor, activity)
    await controller.startLiveActivity()
    XCTAssertEqual(controller.compactStatus, .unavailable)
    // The next start fails at location instead, before any Live Activity is asked for.
    activity.fails = false
    sensor.fails = true
    await controller.startLiveActivity()
    XCTAssertFalse(controller.isDriving)
    XCTAssertEqual(controller.setupStatus, .unavailable)
    XCTAssertEqual(controller.compactStatus, .inactive)
    XCTAssertFalse(controller.isLiveActivityRunning)
    XCTAssertEqual(activity.starts, 1)
  }

  func testInterruptionHandsOverAClearOnlyWhileTheActivityRuns() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    activity.pauseStart = true
    let starting = Task { await controller.carPlayActivated() }
    while activity.startContinuation == nil { await Task.yield() }
    // A clear during startup is handed over, so it reaches the activity once it shows.
    sensor.receive?(.interrupted)
    XCTAssertEqual(activity.invalidations, 1)
    XCTAssertEqual(activity.updates.last?.status, .unavailable)
    activity.startContinuation?.resume()
    await starting.value
    activity.onDismiss?()
    sensor.receive?(.interrupted)
    XCTAssertEqual(activity.invalidations, 1)
    await controller.endDrive()
  }

  func testForegroundWaitEndsAsSoonAsLocationReportsNotInUse() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    let started = ContinuousClock.now
    Task { sensor.receive?(.notInUse) }
    let needed = await controller.needsForegroundStart(waitingUpTo: .seconds(30))
    XCTAssertTrue(needed)
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    await controller.endDrive()
  }

  func testForegroundWaitEndsWhenCarPlayConnects() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    let started = ContinuousClock.now
    Task { controller.carPlayConnected() }
    let needed = await controller.needsForegroundStart(waitingUpTo: .seconds(30))
    XCTAssertFalse(needed)
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    await controller.endDrive()
  }

  func testAReadingDuringTheForegroundWaitSettlesAfterASecond() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    let started = ContinuousClock.now
    Task { sensor.receive?(self.reading()) }
    let needed = await controller.needsForegroundStart(waitingUpTo: .seconds(30))
    XCTAssertFalse(needed)
    let waited = ContinuousClock.now - started
    XCTAssertGreaterThanOrEqual(waited, .seconds(1))
    XCTAssertLessThan(waited, .seconds(10))
    await controller.endDrive()
  }

  func testCancellingTheForegroundWaitNeverNeedsTheForeground() async {
    let sensor = Sensor(), activity = Activity(), controller = make(sensor, activity)
    await controller.startLiveActivity()
    let waiting = Task { await controller.needsForegroundStart(waitingUpTo: .seconds(30)) }
    await Task.yield()
    waiting.cancel()
    let needed = await waiting.value
    XCTAssertFalse(needed)
    XCTAssertTrue(controller.isDriving)
    await controller.endDrive()
  }
}

/// A clock that moves only when a test sets it, and runs the timers that have come due when
/// asked.
final class TestDriveClock: DriveClock {
  private typealias Entry = (id: Int, date: Date, fire: @MainActor () -> Void)
  var now: Date
  private var timers: [Entry] = []
  private var lastID = 0

  nonisolated init(now: Date = Date(timeIntervalSince1970: 1_000)) { self.now = now }

  func timer(at date: Date, _ fire: @escaping @MainActor () -> Void) -> DriveTimer {
    lastID += 1
    let id = lastID
    timers.append((id, date, fire))
    return DriveTimer { [weak self] in self?.timers.removeAll { $0.id == id } }
  }

  /// When the timers still to fire are due, earliest first.
  var pending: [Date] { timers.map(\.date).sorted() }

  /// Runs each timer due by now once, earliest first. Timers set meanwhile wait for the next call.
  func fireDue() {
    let due = timers.filter { $0.date <= now }.sorted(by: Self.earlier).map(\.id)
    for id in due {
      guard let index = timers.firstIndex(where: { $0.id == id }) else { continue }
      timers.remove(at: index).fire()
    }
  }

  /// Moves time on to `date`, running each timer at its own time on the way, earliest first.
  func run(until date: Date) {
    while let next = timers.filter({ $0.date <= date }).min(by: Self.earlier) {
      timers.removeAll { $0.id == next.id }
      if next.date > now { now = next.date }
      next.fire()
    }
    now = date
  }

  nonisolated private static func earlier(_ first: Entry, _ second: Entry) -> Bool {
    (first.date, first.id) < (second.date, second.id)
  }
}
