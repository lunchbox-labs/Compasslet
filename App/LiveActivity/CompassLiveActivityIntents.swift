import AppIntents

/// Starts location from the foreground, because When In Use access can't begin in the
/// background. Without a connected CarPlay scene, the drive ends after the absence limit.
struct StartLiveActivityIntent: AppIntent {
  static var title: LocalizedStringResource { "Start Live Activity" }
  static var description: IntentDescription? {
    IntentDescription(
      "Starts the Compasslet Live Activity for a CarPlay drive. Open Compasslet on CarPlay within a minute to keep it. It ends a minute after CarPlay disconnects."
    )
  }
  static var supportedModes: IntentModes { .foreground(.immediate) }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let drive = CompassAppDelegate.sharedDrive
    let wasRunning =
      drive.isDriving && (drive.compactStatus == .active || drive.compactStatus == .starting)
    await drive.startLiveActivity()
    guard !wasRunning || !drive.isDriving else {
      return .result(dialog: "The Live Activity is already running.")
    }
    return .result(dialog: Self.outcome(of: drive))
  }

  @MainActor
  private static func outcome(of drive: DriveSessionController) -> IntentDialog {
    switch drive.setupStatus {
    case .ready: break
    case .unavailable: return "Travel direction is unavailable on this iPhone right now."
    default: return "Allow precise location for Compasslet in the Settings app, then try again."
    }
    guard drive.isDriving, drive.compactStatus != .unavailable else {
      return
        "The Live Activity couldn’t start. Make sure Live Activities are allowed for Compasslet in the Settings app."
    }
    guard drive.isCarPlayConnected else {
      return "Live Activity started. Open Compasslet on CarPlay within a minute to keep it."
    }
    return "Live Activity started."
  }
}

struct EndLiveActivityIntent: AppIntent {
  static var title: LocalizedStringResource { "End Live Activity" }
  static var description: IntentDescription? {
    IntentDescription("Ends the Compasslet Live Activity and stops using location for it.")
  }
  static var supportedModes: IntentModes { .background }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let drive = CompassAppDelegate.sharedDrive
    let wasDriving = drive.isDriving
    await drive.endLiveActivity()
    guard wasDriving else { return .result(dialog: "The Live Activity isn’t running.") }
    return .result(dialog: "Live Activity ended.")
  }
}

struct CompassAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartLiveActivityIntent(),
      phrases: [
        "Start \(.applicationName) Live Activity",
        "Start the \(.applicationName) Live Activity",
      ],
      shortTitle: "Start Live Activity", systemImageName: "play.circle")
    AppShortcut(
      intent: EndLiveActivityIntent(),
      phrases: [
        "End \(.applicationName) Live Activity",
        "End the \(.applicationName) Live Activity",
      ],
      shortTitle: "End Live Activity", systemImageName: "stop.circle")
  }
}
