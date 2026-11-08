import AppIntents

/// Runs in the background, as from a CarPlay automation on a locked iPhone, because a Live
/// Activity intent can start a Live Activity there. When In Use location may not start in the
/// background, so if location reports that the app isn't in use, or no reading arrives, the
/// intent asks to continue in the foreground and starts again there. Without CarPlay, the
/// drive ends after the absence limit.
struct StartLiveActivityIntent: LiveActivityIntent {
  static var title: LocalizedStringResource { "Start Live Activity" }
  static var description: IntentDescription? {
    IntentDescription(
      "Starts the Compasslet Live Activity for a CarPlay drive. It ends a minute after CarPlay disconnects, or after a minute if CarPlay doesn’t connect."
    )
  }
  static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

  /// How long a background start waits for location before starting in the foreground.
  static let backgroundLocationTimeout: Duration = .seconds(5)

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let drive = CompassAppDelegate.sharedDrive
    let wasRunning =
      drive.isDriving && (drive.compactStatus == .active || drive.compactStatus == .starting)
    await drive.startLiveActivity()
    guard !wasRunning || !drive.isDriving else {
      return .result(dialog: "The Live Activity is already running.")
    }
    if systemContext.currentMode.canContinueInForeground,
      await drive.needsForegroundStart(waitingUpTo: Self.backgroundLocationTimeout),
      !Task.isCancelled
    {
      await drive.endLiveActivity()
      do {
        try await continueInForeground(
          "Unlock your iPhone when you’re parked to start the Compasslet Live Activity.",
          alwaysConfirm: false)
      } catch {
        return .result(dialog: "Open Compasslet when you’re parked to start the Live Activity.")
      }
      await drive.startLiveActivity()
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
    guard drive.isCarPlayConnected || drive.isCarAudioConnected else {
      return "Live Activity started. It ends in a minute unless CarPlay connects."
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
    // A Live Activity left from an earlier launch has no drive in this one, but ending it
    // still ends the Live Activity the user sees.
    let wasRunning = drive.isDriving || drive.hasLiveActivity
    await drive.endLiveActivity()
    guard wasRunning else { return .result(dialog: "The Live Activity isn’t running.") }
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
