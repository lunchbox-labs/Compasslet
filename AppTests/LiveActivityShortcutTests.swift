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
