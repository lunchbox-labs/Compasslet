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
    let outcome = await LiveActivityShortcut.start(
      CompassAppDelegate.sharedDrive,
      canContinueInForeground: systemContext.currentMode.canContinueInForeground,
      waitingUpTo: Self.backgroundLocationTimeout
    ) {
      try await continueInForeground(
        "Unlock your iPhone when you’re parked to start the Compasslet Live Activity.",
        alwaysConfirm: false)
    }
    return .result(dialog: outcome.dialog)
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
    let outcome = await LiveActivityShortcut.end(CompassAppDelegate.sharedDrive)
    return .result(dialog: outcome.dialog)
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

/// What the shortcuts read from and ask of a drive, so their decisions can be tested without
/// location, ActivityKit or the Shortcuts app.
@MainActor
protocol ShortcutDrive: AnyObject {
  var isDriving: Bool { get }
  var compactStatus: DriveSessionController.CompactStatus { get }
  var setupStatus: DriveSessionController.SetupStatus { get }
  var isCarPlayConnected: Bool { get }
  var isCarAudioConnected: Bool { get }
  var hasLiveActivity: Bool { get }
  func startLiveActivity() async
  func endLiveActivity() async
  func needsForegroundStart(waitingUpTo timeout: Duration) async -> Bool
}

extension DriveSessionController: ShortcutDrive {}

/// The Start and End Live Activity shortcuts' decisions, apart from the intents that run them.
enum LiveActivityShortcut {
  enum StartOutcome: Equatable {
    case alreadyRunning, openWhenParked, unavailable, needsPreciseLocation, couldNotStart
    case startedWithoutCarPlay, started
  }

  enum EndOutcome: Equatable { case notRunning, ended }

  /// Starts the drive, and when location can't start from here, ends it and asks to continue
  /// in the foreground, where it starts again.
  @MainActor
  static func start(
    _ drive: some ShortcutDrive, canContinueInForeground: Bool, waitingUpTo timeout: Duration,
    continueInForeground: @MainActor () async throws -> Void
  ) async -> StartOutcome {
    let wasRunning =
      drive.isDriving && (drive.compactStatus == .active || drive.compactStatus == .starting)
    await drive.startLiveActivity()
    guard !wasRunning || !drive.isDriving else { return .alreadyRunning }
    if canContinueInForeground, await drive.needsForegroundStart(waitingUpTo: timeout),
      !Task.isCancelled
    {
      await drive.endLiveActivity()
      do {
        try await continueInForeground()
      } catch {
        return .openWhenParked
      }
      await drive.startLiveActivity()
    }
    return outcome(of: drive)
  }

  /// Ends the drive. A Live Activity left from an earlier launch has no drive in this one, but
  /// ending it still ends the Live Activity the user sees.
  @MainActor
  static func end(_ drive: some ShortcutDrive) async -> EndOutcome {
    let wasRunning = drive.isDriving || drive.hasLiveActivity
    await drive.endLiveActivity()
    return wasRunning ? .ended : .notRunning
  }

  @MainActor
  static func outcome(of drive: some ShortcutDrive) -> StartOutcome {
    switch drive.setupStatus {
    case .ready: break
    case .unavailable: return .unavailable
    default: return .needsPreciseLocation
    }
    guard drive.isDriving, drive.compactStatus != .unavailable else { return .couldNotStart }
    guard drive.isCarPlayConnected || drive.isCarAudioConnected else {
      return .startedWithoutCarPlay
    }
    return .started
  }
}

extension LiveActivityShortcut.StartOutcome {
  var dialog: IntentDialog {
    switch self {
    case .alreadyRunning: "The Live Activity is already running."
    case .openWhenParked: "Open Compasslet when you’re parked to start the Live Activity."
    case .unavailable: "Travel direction is unavailable on this iPhone right now."
    case .needsPreciseLocation:
      "Allow precise location for Compasslet in the Settings app, then try again."
    case .couldNotStart:
      "The Live Activity couldn’t start. Make sure Live Activities are allowed for Compasslet in the Settings app."
    case .startedWithoutCarPlay:
      "Live Activity started. It ends in a minute unless CarPlay connects."
    case .started: "Live Activity started."
    }
  }
}

extension LiveActivityShortcut.EndOutcome {
  var dialog: IntentDialog {
    switch self {
    case .notRunning: "The Live Activity isn’t running."
    case .ended: "Live Activity ended."
    }
  }
}
