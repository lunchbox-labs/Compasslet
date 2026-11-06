import CompassCore
import CoreLocation
import SwiftUI
import TipKit
import XCTest

@testable import Compass

/// Renders every named screen with fixed sensor input for `scripts/screenshots`, which takes a
/// full simulator screenshot of each. Runs only when that script sets `SCREENSHOT_DIRECTORY`.
///
/// A pull request that adds or changes a screen adds or updates its entry in `screens`.
@MainActor
final class ScreenshotTests: XCTestCase {
  struct Screen {
    let name: String
    var increasedContrast = false
    var showsLastRow = false
    /// Captured only when a capture set names it, as for a screen that needs simulator state the
    /// set prepares, such as location access that hasn't been decided.
    var onlyWhenNamed = false
    let content: @MainActor () async -> AnyView
  }

  /// A text size and Bold Text combination applied to the window as the system would apply it.
  struct TextVariant {
    let name: String
    let contentSize: UIContentSizeCategory?
    let bold: Bool

    static let standard = TextVariant(name: "", contentSize: nil, bold: false)

    /// `ax3` and `ax5` are the third and fifth accessibility sizes; `-bold` adds Bold Text.
    init?(named name: String) {
      let bold = name.hasSuffix("-bold")
      let size = bold ? String(name.dropLast("-bold".count)) : name
      switch size {
      case "ax3": contentSize = .accessibilityExtraLarge
      case "ax5": contentSize = .accessibilityExtraExtraExtraLarge
      default: return nil
      }
      self.name = name
      self.bold = bold
    }

    private init(name: String, contentSize: UIContentSizeCategory?, bold: Bool) {
      self.name = name
      self.contentSize = contentSize
      self.bold = bold
    }
  }

  /// System settings a capture set turns on in the simulator before the test starts. The test
  /// checks each against what the system reports, so an image is never taken without it.
  static let systemSettings: [String: @MainActor () -> Bool] = [
    "increase-contrast": { UIAccessibility.isDarkerSystemColorsEnabled },
    "reduce-transparency": { UIAccessibility.isReduceTransparencyEnabled },
  ]

  static let screens: [Screen] = [
    Screen(name: "compass") { await ScreenshotTests.compass() },
    Screen(name: "compass-inactive") { await ScreenshotTests.compass(inactive: true) },
    Screen(name: "compass-inactive-largest-text") {
      AnyView(
        await ScreenshotTests.compass(inactive: true).environment(
          \.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "compass-inactive-no-reading") {
      await ScreenshotTests.compass(heading: nil, inactive: true)
    },
    Screen(name: "compass-large-text") {
      AnyView(await ScreenshotTests.compass().environment(\.dynamicTypeSize, .accessibility3))
    },
    Screen(name: "compass-settings-sheet") { await ScreenshotTests.compass(showsSettings: true) },
    Screen(name: "compass-finding-north") { await ScreenshotTests.compass(heading: nil) },
    Screen(name: "compass-calibration") {
      await ScreenshotTests.compass(heading: .calibrationNeeded)
    },
    Screen(name: "compass-calibration-large-text") {
      AnyView(
        await ScreenshotTests.compass(heading: .calibrationNeeded)
          .environment(\.dynamicTypeSize, .accessibility3))
    },
    Screen(name: "compass-calibration-largest-text") {
      AnyView(
        await ScreenshotTests.compass(heading: .calibrationNeeded)
          .environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "compass-location-denied") { await ScreenshotTests.compass(location: .denied) },
    // The compass asks for location as the app does on its first use, and the simulator shows
    // its real permission prompt over it.
    Screen(name: "compass-location-prompt", onlyWhenNamed: true) {
      await ScreenshotTests.compass(location: .notDetermined)
    },
    Screen(name: "compass-live-activity-start") {
      await ScreenshotTests.compass(carPlay: .connected)
    },
    Screen(name: "compass-live-activity-start-large-text") {
      AnyView(
        await ScreenshotTests.compass(carPlay: .connected)
          .environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "compass-live-activity-end") { await ScreenshotTests.compass(carPlay: .driving) },
    Screen(name: "compass-live-activity-tip") {
      await ScreenshotTests.compass(carPlay: .connected, showsTip: true)
    },
    Screen(name: "tour-welcome") { await ScreenshotTests.compass(tour: .compass) },
    Screen(name: "tour-live-activity-button") {
      await ScreenshotTests.compass(tour: .liveActivity)
    },
    Screen(name: "tour-live-activity-button-large-text") {
      AnyView(
        await ScreenshotTests.compass(tour: .liveActivity)
          .environment(\.dynamicTypeSize, .accessibility3))
    },
    Screen(name: "tour-live-activity-button-carplay") {
      await ScreenshotTests.compass(tour: .liveActivity, carPlay: .connected)
    },
    Screen(name: "tour-shortcuts") { await ScreenshotTests.compass(tour: .shortcuts) },
    Screen(name: "tour-shortcuts-carplay") {
      await ScreenshotTests.compass(tour: .shortcuts, carPlay: .connected)
    },
    Screen(name: "settings") { ScreenshotTests.settings() },
    Screen(name: "settings-largest-text") {
      AnyView(ScreenshotTests.settings().environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "settings-increased-contrast", increasedContrast: true) {
      ScreenshotTests.settings()
    },
    Screen(name: "tour-welcome-increased-contrast", increasedContrast: true) {
      await ScreenshotTests.compass(tour: .compass)
    },
    Screen(name: "tour-live-activity-button-largest-text") {
      AnyView(
        await ScreenshotTests.compass(tour: .liveActivity)
          .environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "settings-bottom") {
      AnyView(ScreenshotTests.settings().defaultScrollAnchor(.bottom))
    },
    Screen(name: "settings-diagnostics-export", onlyWhenNamed: true) {
      AnyView(
        ScreenshotTests.settings().sheet(isPresented: .constant(true)) {
          DiagnosticsShareSheet(url: ScreenshotTests.sampleDiagnosticsExport)
        })
    },
    Screen(name: "settings-appearance") {
      AnyView(NavigationStack { AppearanceSettingsView() })
    },
    Screen(name: "settings-appearance-global") {
      AnyView(NavigationStack { AppearanceDetailView(surface: nil) })
    },
    Screen(name: "settings-appearance-global-reset", showsLastRow: true) {
      AnyView(NavigationStack { AppearanceDetailView(surface: nil) })
    },
    Screen(name: "settings-appearance-global-reset-largest-text", showsLastRow: true) {
      AnyView(
        NavigationStack {
          AppearanceDetailView(surface: nil)
            .environment(\.dynamicTypeSize, .accessibility5)
        })
    },
    Screen(name: "settings-appearance-global-largest-text") {
      AnyView(
        NavigationStack { AppearanceDetailView(surface: nil) }
          .environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "settings-appearance-iphone") {
      AnyView(NavigationStack { AppearanceDetailView(surface: .phone) })
    },
    Screen(name: "settings-appearance-iphone-largest-text") {
      AnyView(
        NavigationStack { AppearanceDetailView(surface: .phone) }
          .environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "settings-appearance-live-activity") {
      AnyView(NavigationStack { AppearanceDetailView(surface: .activity) })
    },
    Screen(name: "settings-appearance-live-activity-largest-text") {
      AnyView(
        NavigationStack { AppearanceDetailView(surface: .activity) }
          .environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "settings-appearance-minor-ticks") { ScreenshotTests.editor(.minorTicks) },
    Screen(name: "settings-appearance-cardinal-labels") { ScreenshotTests.editor(.labels) },
    Screen(name: "settings-appearance-cardinal-labels-largest-text") {
      AnyView(ScreenshotTests.editor(.labels).environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "settings-appearance-rotation") { ScreenshotTests.editor(.rotation) },
    Screen(name: "settings-appearance-reduce-motion") { ScreenshotTests.editor(.reduceMotion) },
    Screen(name: "live-activity") { AnyView(LiveActivityScreen()) },
    Screen(name: "live-activity-hidden-time") { AnyView(LiveActivityScreen(mode: .hidden)) },
    Screen(name: "live-activity-elapsed-time") { AnyView(LiveActivityScreen(mode: .elapsed)) },
    Screen(name: "live-activity-largest-text") {
      AnyView(LiveActivityScreen().environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "live-activity-status") { AnyView(LiveActivityScreen(status: .slow)) },
    Screen(name: "live-activity-status-largest-text") {
      AnyView(LiveActivityScreen(status: .slow).environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "carplay-dial") { AnyView(CarPlayDialScreen()) },
  ]

  private var directory: URL?
  private var nameFilter: [String] = []
  private var namedScreens: [String] = []
  private var textVariants = [TextVariant.standard]
  private var interfaceStyle = UIUserInterfaceStyle.light

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["SCREENSHOT_DIRECTORY"], !path.isEmpty else {
      throw XCTSkip("Captured only by scripts/screenshots")
    }
    directory = URL(fileURLWithPath: path, isDirectory: true)
    nameFilter = Self.list(environment["SCREENSHOT_FILTER"])
    namedScreens = Self.list(environment["SCREENSHOT_SCREENS"])
    interfaceStyle = environment["SCREENSHOT_APPEARANCE"] == "dark" ? .dark : .light
    let variantNames = Self.list(environment["SCREENSHOT_TEXT_VARIANTS"])
    if !variantNames.isEmpty {
      textVariants = try variantNames.map { name in
        try XCTUnwrap(TextVariant(named: name), "Unknown text variant \(name)")
      }
    }
    try checkSystemSettings(expectedOn: Self.list(environment["SCREENSHOT_SYSTEM_SETTINGS"]))
  }

  private static func list(_ value: String?) -> [String] {
    (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Fails before any capture when the simulator doesn't report a setting the run asked for, or
  /// reports one it didn't, so no image claims a setting it wasn't taken with.
  private func checkSystemSettings(expectedOn: [String]) throws {
    struct SystemSettingMismatch: Error {}
    for name in expectedOn where Self.systemSettings[name] == nil {
      XCTFail("Unknown system setting \(name)")
      throw SystemSettingMismatch()
    }
    for (name, isOn) in Self.systemSettings.sorted(by: { $0.key < $1.key }) {
      let expected = expectedOn.contains(name)
      let reported = isOn()
      if reported != expected {
        XCTFail(
          "The simulator reports \(name) \(reported ? "on" : "off"), "
            + "but this run expects it \(expected ? "on" : "off")")
        throw SystemSettingMismatch()
      }
    }
  }

  override func tearDown() async throws {
    CompassView.makeHeadingController = { HeadingController(sensor: DeviceHeadingSensor()) }
    CompassView.makeLocationController = { PhoneLocationController() }
  }

  func testCaptureScreens() async throws {
    let directory = try XCTUnwrap(directory)
    let unknown = namedScreens.filter { name in !Self.screens.contains { $0.name == name } }
    XCTAssertTrue(unknown.isEmpty, "No screen is named \(unknown)")
    let listed =
      namedScreens.isEmpty
      ? Self.screens.filter { !$0.onlyWhenNamed }
      : namedScreens.compactMap { name in Self.screens.first { $0.name == name } }
    let selected = listed.filter { screen in
      nameFilter.isEmpty || nameFilter.contains { screen.name.hasPrefix($0) }
    }
    XCTAssertFalse(selected.isEmpty, "No screen name starts with \(nameFilter)")
    if selected.contains(where: { $0.name == "settings-diagnostics-export" }) {
      try Self.writeSampleDiagnosticsExport()
    }
    for variant in textVariants {
      for screen in selected {
        let asksForLocation = screen.name == "compass-location-prompt"
        if asksForLocation { try requireUndecidedLocation() }
        let window = try makeWindow(
          await screen.content(), increasedContrast: screen.increasedContrast, text: variant)
        // Long enough for the first readings, navigation titles and any appearance animation.
        try await Task.sleep(for: .seconds(2))
        if screen.showsLastRow { try await showLastRow(in: window) }
        let name = variant.name.isEmpty ? screen.name : screen.name + "-" + variant.name
        try await requestScreenshot(name, in: directory)
        // Still undecided means the prompt hadn't been answered or dismissed when captured.
        if asksForLocation { try requireUndecidedLocation() }
        window.isHidden = true
      }
    }
  }

  private func requireUndecidedLocation() throws {
    struct LocationAlreadyDecided: Error {}
    let status = CLLocationManager().authorizationStatus
    if status != .notDetermined {
      XCTFail("The location prompt needs undecided location access, not \(status.rawValue)")
      throw LocationAlreadyDecided()
    }
  }

  private func showLastRow(in window: UIWindow) async throws {
    func collections(in view: UIView) -> [UICollectionView] {
      (view as? UICollectionView).map { [$0] }
        ?? view.subviews.flatMap { collections(in: $0) }
    }
    let forms = collections(in: window)
    XCTAssertEqual(forms.count, 1, "Expected one Form to scroll")
    let form = try XCTUnwrap(forms.first)
    form.layoutIfNeeded()
    let section = try XCTUnwrap((0..<form.numberOfSections).last)
    let item = try XCTUnwrap((0..<form.numberOfItems(inSection: section)).last)
    let lastRow = IndexPath(item: item, section: section)
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
      form.scrollToItem(at: lastRow, at: .bottom, animated: false)
      try await Task.sleep(for: .milliseconds(100))
      form.layoutIfNeeded()
      let row = try XCTUnwrap(form.layoutAttributesForItem(at: lastRow))
      let viewport = form.bounds.inset(by: form.adjustedContentInset)
      if form.cellForItem(at: lastRow) != nil, viewport.contains(row.frame) { return }
    } while ContinuousClock.now < deadline
    struct LastRowNotVisible: Error {}
    XCTFail("The reset row must be fully visible before capture")
    throw LastRowNotVisible()
  }

  private func makeWindow(_ view: AnyView, increasedContrast: Bool, text: TextVariant) throws
    -> UIWindow
  {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = interfaceStyle
    // Without an override the window follows the simulator's Increase Contrast setting, which
    // the run has checked. Text size and Bold Text are always set, so a simulator left with
    // either on can't change an image.
    if increasedContrast { window.traitOverrides.accessibilityContrast = .high }
    window.traitOverrides.preferredContentSizeCategory = text.contentSize ?? .large
    window.traitOverrides.legibilityWeight = text.bold ? .bold : .regular
    window.windowLevel = .alert + 1
    // A window outside the app's SwiftUI scene reports itself inactive, which pauses the
    // compass, so the screens render as the active app does, with the app root's tint.
    window.rootViewController = UIHostingController(
      rootView: view.environment(\.scenePhase, .active).tint(Color.accentColor))
    window.makeKeyAndVisible()
    return window
  }

  /// The script watches the directory, saves a full simulator screenshot for each request and
  /// then writes a matching `.done` file.
  private func requestScreenshot(_ name: String, in directory: URL) async throws {
    let done = directory.appendingPathComponent("\(name).done")
    try Data().write(to: directory.appendingPathComponent("\(name).request"))
    // A busy hosted runner has taken over 80 seconds for one simulator screenshot.
    for _ in 0..<1_800 where !FileManager.default.fileExists(atPath: done.path) {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: done.path), "No screenshot was taken of \(name)")
  }

  enum CarPlay { case disconnected, connected, driving }

  private static func compass(
    heading: FixedHeadingSensor.Reading? = .northeast,
    location: FixedTravelSensor.Access = .allowed,
    tour: OnboardingState.Step? = nil,
    carPlay: CarPlay = .disconnected,
    showsTip: Bool = false,
    inactive: Bool = false,
    showsSettings: Bool = false
  ) async -> AnyView {
    CompassView.makeHeadingController = {
      let sensor = FixedHeadingSensor(reading: heading)
      let controller = HeadingController(sensor: sensor)
      if inactive {
        controller.start()
        if let heading {
          sensor.receive?(
            .reading(degrees: heading.degrees, accuracy: heading.accuracy, timestamp: .now))
        }
        controller.stop(preservingLastReading: true)
      }
      return controller
    }
    CompassView.makeLocationController = {
      let sensor = FixedPhoneLocationSensor(allowed: location == .allowed)
      let controller = PhoneLocationController(sensor: sensor, cityLookup: FixedCityLookup())
      if inactive {
        controller.start()
        sensor.receive?(
          .location(
            CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009),
              altitude: 48, horizontalAccuracy: 5, verticalAccuracy: 3, timestamp: .now)))
        controller.stop(preservingLastReading: true)
      }
      return controller
    }
    let drive = drive(location: location)
    switch carPlay {
    case .disconnected: break
    case .connected: drive.carPlayConnected()
    case .driving: await drive.carPlayActivated()
    }
    let onboarding = onboarding(at: tour)
    if !showsTip { onboarding.liveActivityTip.invalidate(reason: .actionPerformed) }
    return AnyView(
      CompassView(drive: drive, onboarding: onboarding, showingSettings: showsSettings)
        .environment(\.scenePhase, inactive ? .inactive : .active))
  }

  /// TipKit remembers a shown tip across runs on the same simulator, so each screen gets a tip
  /// id it hasn't shown. Separate defaults keep the tour state off the app host's.
  private static func onboarding(at step: OnboardingState.Step?) -> OnboardingState {
    let suite = "screenshots.onboarding"
    guard let defaults = UserDefaults(suiteName: suite) else {
      preconditionFailure("No defaults suite named \(suite)")
    }
    defaults.removePersistentDomain(forName: suite)
    defaults.set(step == nil, forKey: OnboardingState.tourCompletedKey)
    defaults.set(Int.random(in: 1...Int(Int32.max)), forKey: OnboardingState.tipGenerationKey)
    let onboarding = OnboardingState(defaults: defaults)
    while let current = onboarding.step, let step, current.rawValue < step.rawValue {
      onboarding.advance(carPlayConnected: false)
    }
    return onboarding
  }

  private static func settings() -> AnyView {
    AnyView(CompassSettingsView(drive: drive(location: .allowed), showTour: {}))
  }

  /// A small file with the real export's name, since the share sheet previews its name and type.
  private static let sampleDiagnosticsExport = FileManager.default.temporaryDirectory
    .appendingPathComponent("screenshot-diagnostics", isDirectory: true)
    .appendingPathComponent("compass-diagnostics.json")

  private static func writeSampleDiagnosticsExport() throws {
    try FileManager.default.createDirectory(
      at: sampleDiagnosticsExport.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"entries\":[]}\n".utf8).write(to: sampleDiagnosticsExport, options: .atomic)
  }

  private static func editor(_ option: AppearanceOption) -> AnyView {
    AnyView(
      NavigationStack { AppearanceOptionEditor(surface: nil, option: option, store: .shared) })
  }

  private static func drive(location: FixedTravelSensor.Access) -> DriveSessionController {
    DriveSessionController(
      sensor: FixedTravelSensor(access: location), activity: IdleActivity(),
      automaticTick: false)
  }
}

/// A heading sensor that repeats one reading, fresh each time, while it runs.
@MainActor
private final class FixedHeadingSensor: HeadingSensor {
  struct Reading {
    let degrees: Double
    let accuracy: Double

    static let northeast = Reading(degrees: 47, accuracy: 5)
    /// Core Location reports a negative accuracy when the compass needs calibration.
    static let calibrationNeeded = Reading(degrees: 47, accuracy: -1)
  }

  let reading: Reading?
  var receive: ((HeadingEvent) -> Void)?
  var available: Bool { true }
  private var repeating: Task<Void, Never>?

  init(reading: Reading?) { self.reading = reading }

  func start() {
    guard let reading else { return }
    repeating = Task { [weak self] in
      while !Task.isCancelled {
        self?.receive?(
          .reading(degrees: reading.degrees, accuracy: reading.accuracy, timestamp: .now))
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  func stop() {
    repeating?.cancel()
    repeating = nil
  }
}

/// A precise fix at Apple Park, repeated while the sensor runs so it never goes stale.
@MainActor
private final class FixedPhoneLocationSensor: PhoneLocationSensor {
  let allowed: Bool
  var receive: ((PhoneLocationEvent) -> Void)?
  var authorized: Bool { allowed }
  var precise: Bool { true }
  var servicesEnabled: Bool { true }
  private var repeating: Task<Void, Never>?

  init(allowed: Bool) { self.allowed = allowed }

  func start() {
    repeating = Task { [weak self] in
      while !Task.isCancelled {
        self?.receive?(
          .location(
            CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009),
              altitude: 48, horizontalAccuracy: 5, verticalAccuracy: 3, timestamp: .now)))
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func stop() {
    repeating?.cancel()
    repeating = nil
  }
}

@MainActor
private final class FixedCityLookup: PhoneCityLookup {
  func lookup(_ location: CLLocation, completion: @escaping @MainActor (String?) -> Void) {
    completion("Cupertino, CA")
  }

  func cancel() {}
}

/// Travel location for the drive controller; it only decides the phone's location status here.
@MainActor
private final class FixedTravelSensor: TravelLocationSensor {
  enum Access { case allowed, denied, notDetermined }

  let access: Access
  var receive: ((TravelSensorEvent) -> Void)?
  /// Asks the system for real, so the simulator shows its prompt while access is undecided.
  private var permissionManager: CLLocationManager?
  var authorization: TravelAuthorization {
    switch access {
    case .allowed: .authorized
    case .denied: .denied
    case .notDetermined: .notDetermined
    }
  }
  var fullAccuracy: Bool { true }
  var servicesEnabled: Bool { true }
  var available: Bool { true }

  init(access: Access) { self.access = access }

  func requestAuthorization() {
    guard access == .notDetermined else { return }
    let manager = CLLocationManager()
    permissionManager = manager
    manager.requestWhenInUseAuthorization()
  }
  func start() throws {}
  func stop() {}
}

@MainActor
private final class IdleActivity: CompassActivityPresenting {
  var onDismiss: (() -> Void)?
  var canStartActivities: Bool { true }
  func start() async throws {}
  func update(_ presentation: TravelPresentation) async {}
  func end() async {}
}

/// The Lock Screen and CarPlay Live Activity cards as the app renders them, since the
/// simulator can't show a running Live Activity without CarPlay.
private struct LiveActivityScreen: View {
  var mode: ActivityTimestampMode = .time
  /// Anything but `.usable` shows that status instead of a reading.
  var status: CompassActivityAttributes.Status = .usable

  private var state: CompassActivityAttributes.ContentState {
    var appearance = AppearanceValues()
    appearance.lockScreenTimestamp = mode
    appearance.carPlayActivityTimestamp = mode
    return .init(
      bearing: status == .usable ? 47 : nil, status: status,
      sampleTime: .now.addingTimeInterval(-12), expiry: nil, appearance: appearance)
  }

  var body: some View {
    VStack(spacing: 32) {
      Spacer()
      LiveActivityExample(presentation: .lockScreen, state: state, title: "Lock Screen")
      LiveActivityExample(presentation: .carPlay, state: state, title: "CarPlay")
      Spacer()
    }
    // The Lock Screen banner is 22 points narrower than the screen.
    .padding(.horizontal, 11)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemGroupedBackground))
  }
}

/// The CarPlay dial thumbnail as the car receives it, drawn in the window's appearance.
private struct CarPlayDialScreen: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let image = CarPlayCompassTemplate.dialImage(
      course: 59,
      traits: UITraitCollection { traits in
        traits.displayScale = 3
        traits.userInterfaceStyle = colorScheme == .dark ? .dark : .light
      })
    Image(uiImage: image)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(uiColor: .systemGroupedBackground))
  }
}
