import AppIntents

/// Starts location from the foreground, because When In Use access can't begin in the
/// background. Without a connected CarPlay scene, the drive ends after the absence limit.
struct StartLiveActivityIntent: AppIntent {
  static var title: LocalizedStringResource { "Start Live Activity" }
  static var description: IntentDescription? {
    IntentDescription(
      "Starts the Compasslet Live Activity for a CarPlay drive. It ends a minute after CarPlay disconnects, or after a minute if Compasslet isn’t open on CarPlay."
    )
  }
  static var supportedModes: IntentModes { .foreground(.immediate) }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let drive = CompassAppDelegate.sharedDrive
    await drive.startLiveActivity()
    return .result(dialog: Self.outcome(of: drive))
  }

  @MainActor
  private static func outcome(of drive: DriveSessionController) -> IntentDialog {
    guard drive.setupStatus == .ready else {
      return "Compasslet needs precise location access to start the Live Activity."
    }
    guard drive.isDriving, drive.compactStatus != .unavailable else {
      return
        "The Live Activity couldn’t start. Make sure Live Activities are allowed for Compasslet in the Settings app."
    }
    guard drive.isCarPlayConnected else {
      return "Live Activity started. It ends after a minute unless Compasslet is open on CarPlay."
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
    await CompassAppDelegate.sharedDrive.endLiveActivity()
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
      shortTitle: "Start Live Activity", systemImageName: "location.north.circle")
    AppShortcut(
      intent: EndLiveActivityIntent(),
      phrases: [
        "End \(.applicationName) Live Activity",
        "End the \(.applicationName) Live Activity",
      ],
      shortTitle: "End Live Activity", systemImageName: "xmark.circle")
  }
}
