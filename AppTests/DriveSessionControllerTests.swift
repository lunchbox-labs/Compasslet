import CompassCore
import XCTest
@testable import Compass

@MainActor
final class DriveSessionControllerTests: XCTestCase {
  final class Sensor: TravelLocationSensor {
    var authorization: TravelAuthorization = .authorized
    var fullAccuracy = true
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

  func testPhoneLaunchDoesNotAcquireAndPhoneRequestIsOnce() {
    let sensor = Sensor(), activity = Activity()
    sensor.authorization = .notDetermined
    let controller = make(sensor, activity)
    XCTAssertEqual(sensor.starts, 0)
    controller.requestPhoneAuthorization(isForeground: false)
    XCTAssertEqual(sensor.requests, 0)
    controller.requestPhoneAuthorization(isForeground: true)
    controller.requestPhoneAuthorization(isForeground: true)
    XCTAssertEqual(sensor.requests, 1)
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
    for authorization in [TravelAuthorization.notDetermined, .denied, .restricted] {
      let sensor = Sensor(), activity = Activity()
      sensor.authorization = authorization
      let controller = make(sensor, activity)
      await controller.carPlayActivated()
      XCTAssertFalse(controller.isDriving)
      XCTAssertEqual(controller.setupStatus, .permissionRequired)
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
