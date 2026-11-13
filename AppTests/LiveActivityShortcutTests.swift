import CompassCore
import Foundation
import Testing
@testable import Compass

@MainActor
private final class FakeDrive: ShortcutDrive {
  enum Call: Equatable { case start, end, wait(Duration), continueInForeground }

  var isDriving = false
  var compactStatus: DriveSessionController.CompactStatus = .inactive
  var setupStatus: DriveSessionController.SetupStatus = .ready
  var isCarPlayConnected = false
  var isCarAudioConnected = false
  var hasLiveActivity = false
  /// What a start leaves the Live Activity as; nil leaves no drive running.
  var startResult: DriveSessionController.CompactStatus? = .active
  /// Whether a start finds the drive ended under it, as when a limit ends it meanwhile.
  var startEndsDrive = false
  var needsForeground = false
  private(set) var calls: [Call] = []

  func startLiveActivity() async {
    calls.append(.start)
    if startEndsDrive {
      isDriving = false
      compactStatus = .inactive
      return
    }
    guard let startResult else { return }
    isDriving = true
    compactStatus = startResult
    hasLiveActivity = startResult != .unavailable
  }

  func endLiveActivity() async {
    calls.append(.end)
    isDriving = false
    compactStatus = .inactive
    hasLiveActivity = false
  }

  func needsForegroundStart(waitingUpTo timeout: Duration) async -> Bool {
    calls.append(.wait(timeout))
    return needsForeground
  }

  func continueInForeground() { calls.append(.continueInForeground) }
}

private struct Declined: Error {}

@MainActor
struct LiveActivityShortcutTests {
  private func start(
    _ drive: FakeDrive, canContinueInForeground: Bool = true, foregroundFails: Bool = false
  ) async -> LiveActivityShortcut.StartOutcome {
    await LiveActivityShortcut.start(
      drive, canContinueInForeground: canContinueInForeground, waitingUpTo: .seconds(5)
    ) {
      drive.continueInForeground()
      if foregroundFails { throw Declined() }
    }
  }

  @Test(arguments: [DriveSessionController.CompactStatus.active, .starting])
  func runningDriveIsLeftAsItIs(status: DriveSessionController.CompactStatus) async {
    let drive = FakeDrive()
    drive.isDriving = true
    drive.compactStatus = status
    drive.startResult = status
    #expect(await start(drive) == .alreadyRunning)
    // Asking again doesn't wait for location or end the drive.
    #expect(drive.calls == [.start])
  }

  @Test func driveThatEndsDuringTheStartIsNotReportedAsRunning() async {
    let drive = FakeDrive()
    drive.isDriving = true
    drive.compactStatus = .active
    drive.startEndsDrive = true
    #expect(await start(drive) == .couldNotStart)
    #expect(drive.calls == [.start, .wait(.seconds(5))])
  }

  @Test func driveWhoseLiveActivityWasDismissedStartsAgain() async {
    let drive = FakeDrive()
    drive.isDriving = true
    drive.compactStatus = .dismissed
    drive.isCarAudioConnected = true
    #expect(await start(drive) == .started)
    #expect(drive.calls == [.start, .wait(.seconds(5))])
  }

  @Test func startNamesWhetherTheCarIsConnected() async {
    let parked = FakeDrive()
    #expect(await start(parked) == .startedWithoutCarPlay)
    let carPlay = FakeDrive()
    carPlay.isCarPlayConnected = true
    #expect(await start(carPlay) == .started)
    let carAudio = FakeDrive()
    carAudio.isCarAudioConnected = true
    #expect(await start(carAudio) == .started)
  }

  @Test func startThatCantContinueInTheForegroundDoesNotWaitForLocation() async {
    let drive = FakeDrive()
    drive.needsForeground = true
    #expect(await start(drive, canContinueInForeground: false) == .startedWithoutCarPlay)
    #expect(drive.calls == [.start])
  }

  @Test func backgroundStartWithoutLocationMovesToTheForegroundAndStartsAgain() async {
    let drive = FakeDrive()
    drive.needsForeground = true
    drive.isCarAudioConnected = true
    #expect(await start(drive) == .started)
    #expect(drive.calls == [.start, .wait(.seconds(5)), .end, .continueInForeground, .start])
    #expect(drive.isDriving)
  }

  @Test func cancelledStartDoesNotMoveToTheForeground() async {
    let drive = FakeDrive()
    drive.needsForeground = true
    let task = Task {
      await LiveActivityShortcut.start(
        drive, canContinueInForeground: true, waitingUpTo: .seconds(5)
      ) { drive.continueInForeground() }
    }
    task.cancel()
    #expect(await task.value == .startedWithoutCarPlay)
    #expect(drive.calls == [.start, .wait(.seconds(5))])
    #expect(drive.isDriving)
  }

  @Test func declinedForegroundStartLeavesTheDriveEnded() async {
    let drive = FakeDrive()
    drive.needsForeground = true
    #expect(await start(drive, foregroundFails: true) == .openWhenParked)
    #expect(drive.calls == [.start, .wait(.seconds(5)), .end, .continueInForeground])
    #expect(!drive.isDriving)
    #expect(!drive.hasLiveActivity)
  }

  @Test func startThatCantRunExplainsWhy() async {
    let unavailable = FakeDrive()
    unavailable.setupStatus = .unavailable
    unavailable.startResult = nil
    #expect(await start(unavailable) == .unavailable)

    for status: DriveSessionController.SetupStatus in [
      .permissionRequired, .denied, .restricted, .servicesDisabled, .preciseLocationRequired,
    ] {
      let drive = FakeDrive()
      drive.setupStatus = status
      drive.startResult = nil
      #expect(await start(drive) == .needsPreciseLocation)
    }

    let noDrive = FakeDrive()
    noDrive.startResult = nil
    #expect(await start(noDrive) == .couldNotStart)

    let noActivity = FakeDrive()
    noActivity.startResult = .unavailable
    noActivity.isCarPlayConnected = true
    #expect(await start(noActivity) == .couldNotStart)
  }

  @Test func endReportsWhetherAnythingWasRunningAndAlwaysEnds() async {
    let driving = FakeDrive()
    driving.isDriving = true
    #expect(await LiveActivityShortcut.end(driving) == .ended)
    #expect(driving.calls == [.end])

    // A Live Activity left from an earlier launch has no drive, but still counts.
    let leftOver = FakeDrive()
    leftOver.hasLiveActivity = true
    #expect(await LiveActivityShortcut.end(leftOver) == .ended)
    #expect(!leftOver.hasLiveActivity)

    let idle = FakeDrive()
    #expect(await LiveActivityShortcut.end(idle) == .notRunning)
    #expect(idle.calls == [.end])
  }
}

/// The car audio route as a drive reads it, which a test changes without telling the drive, as
/// when the notification is missed while the app is suspended.
@MainActor
private final class CarAudioRoute { var connected = false }

/// The Start shortcut, run away from the car, on the real drive. It says the drive ends in a
/// minute unless CarPlay connects, so that minute runs from the shortcut, whatever Auto-Stop is
/// set to, also when it starts again the Live Activity of a drive kept after the car left
/// ([#357](https://github.com/lunchbox-labs/compasslet/issues/357)).
@Suite(.timeLimit(.minutes(1))) @MainActor
struct StartShortcutAwayFromTheCarTests {
  let clock: TestDriveClock
  let sensor: TestTravelSensor
  let activity: TestActivityPresenter
  private let carAudio: CarAudioRoute

  init() {
    clock = TestDriveClock()
    sensor = TestTravelSensor()
    activity = TestActivityPresenter()
    carAudio = CarAudioRoute()
  }

  private func makeDrive(autoStop: LiveActivityAutoStop) -> DriveSessionController {
    let carAudio = carAudio
    return DriveSessionController(
      sensor: sensor, activity: activity, clock: clock, carAudioRoute: { carAudio.connected },
      autoStop: { autoStop })
  }

  private func reading() -> TravelSensorEvent {
    .reading(
      TravelReading(
        courseDegrees: 90, courseAccuracyDegrees: 2, speedMetersPerSecond: 10,
        speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 5, timestamp: clock.now))
  }

  /// Runs the Start shortcut as a CarPlay automation does, in the background with location
  /// running, so it never needs the foreground.
  private func runStartShortcut(
    _ drive: DriveSessionController
  ) async -> LiveActivityShortcut.StartOutcome {
    await LiveActivityShortcut.start(
      drive, canContinueInForeground: true, waitingUpTo: .seconds(5)
    ) { Issue.record("The shortcut asked to continue in the foreground") }
  }

  /// A CarPlay drive whose Live Activity was dismissed, kept after CarPlay disconnects, 50 seconds
  /// into the minute it then has.
  private func keptDrive(_ drive: DriveSessionController) async {
    await drive.carPlayActivated()
    sensor.receive?(reading())
    activity.onDismiss?()
    drive.carPlayResignedActive()
    drive.carPlayDisconnected()
    let left = clock.now
    clock.run(until: left + 50)
    sensor.receive?(reading())
    #expect(drive.isDriving)
    #expect(drive.compactStatus == .dismissed)
  }

  /// Checks that the drive ends just after the start window from `start`, and not before.
  private func expectEndAfterTheStartWindow(
    of drive: DriveSessionController, from start: Date
  ) async {
    clock.run(until: start + DriveSessionController.carPlayAbsenceLimit)
    #expect(drive.isDriving)
    clock.run(until: start + DriveSessionController.carPlayAbsenceLimit + 0.1)
    #expect(!drive.isDriving)
    await drive.waitForPendingOperations()
    #expect(sensor.stops == 1)
  }

  @Test(arguments: [LiveActivityAutoStop.oneMinute, .never])
  func keptDriveEndsAMinuteAfterTheShortcut(autoStop: LiveActivityAutoStop) async {
    let drive = makeDrive(autoStop: autoStop)
    await keptDrive(drive)
    #expect(await runStartShortcut(drive) == .startedWithoutCarPlay)
    #expect(drive.compactStatus == .active)
    #expect(sensor.starts == 1)
    // Not the Auto-Stop time from when the car left: 10 seconds from now for a minute, and
    // never for Never.
    await expectEndAfterTheStartWindow(of: drive, from: clock.now)
  }

  @Test(arguments: [LiveActivityAutoStop.fiveMinutes, .never])
  func carConnectingAfterTheShortcutKeepsTheDriveUntilAutoStop(
    autoStop: LiveActivityAutoStop
  ) async {
    let drive = makeDrive(autoStop: autoStop)
    await keptDrive(drive)
    #expect(await runStartShortcut(drive) == .startedWithoutCarPlay)
    clock.run(until: clock.now + 30)
    drive.carPlayConnected()
    clock.run(until: clock.now + 10 * 60)
    #expect(drive.isDriving)
    // Once the car leaves again, the drive's Live Activity runs, so Auto-Stop applies.
    drive.carPlayDisconnected()
    let left = clock.now
    clock.run(until: left + 5 * 60)
    #expect(drive.isDriving)
    clock.run(until: left + 5 * 60 + 0.1)
    #expect(drive.isDriving == (autoStop == .never))
    await drive.endDrive()
  }

  /// Car audio that went to CarPlay before the drive's next beat read it, as when a CarPlay
  /// automation runs the shortcut before Compasslet opens on CarPlay.
  @Test(arguments: [LiveActivityAutoStop.oneMinute, .never])
  func carAudioAtTheShortcutCountsAsTheCar(autoStop: LiveActivityAutoStop) async {
    let drive = makeDrive(autoStop: autoStop)
    await keptDrive(drive)
    carAudio.connected = true
    #expect(await runStartShortcut(drive) == .started)
    clock.run(until: clock.now + 10 * 60)
    #expect(drive.isDriving)
    #expect(drive.compactStatus == .active)
    await drive.endDrive()
  }

  @Test func keptDriveDismissedAgainAwayFromTheCarEnds() async {
    let drive = makeDrive(autoStop: .never)
    await keptDrive(drive)
    #expect(await runStartShortcut(drive) == .startedWithoutCarPlay)
    activity.onDismiss?()
    #expect(!drive.isDriving)
    await drive.waitForPendingOperations()
    #expect(sensor.stops == 1)
  }

  @Test(arguments: [LiveActivityAutoStop.oneMinute, .never])
  func freshStartEndsAMinuteAfterTheShortcut(autoStop: LiveActivityAutoStop) async {
    let drive = makeDrive(autoStop: autoStop)
    let shortcut = Task { await runStartShortcut(drive) }
    while !drive.isDriving { await Task.yield() }
    let started = clock.now
    sensor.receive?(reading())
    #expect(await shortcut.value == .startedWithoutCarPlay)
    #expect(drive.compactStatus == .active)
    #expect(sensor.starts == 1)
    await expectEndAfterTheStartWindow(of: drive, from: started)
  }
}
