import CompassCore
import CoreLocation
import SwiftUI
import TipKit
import XCTest

@testable import Compass

/// Renders every named screen with fixed sensor input for `scripts/screenshots`, which takes a
/// full simulator screenshot of each, and of each further part of a screen that scrolls. Runs
/// only when that script sets `SCREENSHOT_DIRECTORY`.
///
/// A pull request that adds or changes a screen adds or updates its entry in `screens`.
@MainActor
final class ScreenshotTests: XCTestCase {
  struct Screen {
    let name: String
    var increasedContrast = false
    var showsLastRow = false
    /// Scrolls the screen's one Form to its end, below its last footer.
    var showsEnd = false
    /// The Live Activity button's tip is up, rather than invalidated, when captured.
    var showsTip = false
    /// Captured only when a capture set names it, as for a screen that needs simulator state the
    /// set prepares, such as location access that hasn't been decided.
    var onlyWhenNamed = false
    /// Presents the system share sheet, whose content loads after the sheet appears.
    var presentsSheet = false
    /// Scrolls through the rest of the screen after its first capture, when it has more than
    /// fits, and captures each part. Off for a screen whose point is what is over it.
    var scrollsInParts = true
    let content: @MainActor () async -> AnyView

    /// A screen shown at a chosen scroll position, or with a tip or sheet over it, is captured
    /// only as it is.
    var capturesScrolledParts: Bool {
      scrollsInParts && !showsEnd && !showsLastRow && !showsTip && !presentsSheet
    }
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
    // The sheet's Form is the settings screen, which has its own parts.
    Screen(name: "compass-settings-sheet", scrollsInParts: false) {
      await ScreenshotTests.compass(showsSettings: true)
    },
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
    Screen(name: "compass-live-activity-tip", showsTip: true) {
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
    Screen(name: "settings-bottom", showsEnd: true) { ScreenshotTests.settings() },
    // Location is undecided, as after Allow Once ends, so Settings offers the prompt.
    Screen(name: "settings-location-undecided") {
      ScreenshotTests.settings(location: .notDetermined)
    },
    Screen(name: "settings-diagnostics-export", onlyWhenNamed: true, presentsSheet: true) {
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
    Screen(name: "settings-live-activity") { ScreenshotTests.liveActivitySettings() },
    Screen(name: "settings-live-activity-largest-text") {
      AnyView(
        ScreenshotTests.liveActivitySettings().environment(\.dynamicTypeSize, .accessibility5))
    },
    // Choices other than the standard ones, with the lowest update frequency and no auto-stop.
    Screen(name: "settings-live-activity-never") {
      ScreenshotTests.liveActivitySettings {
        $0.updateFrequency = .everyFifteenSeconds
        $0.autoStop = .never
      }
    },
    Screen(name: "live-activity") { AnyView(LiveActivityScreen()) },
    Screen(name: "live-activity-hidden-time") { AnyView(LiveActivityScreen(mode: .hidden)) },
    Screen(name: "live-activity-elapsed-time") { AnyView(LiveActivityScreen(mode: .elapsed)) },
    Screen(name: "live-activity-largest-text") {
      AnyView(LiveActivityScreen().environment(\.dynamicTypeSize, .accessibility5))
    },
    Screen(name: "live-activity-waiting") { AnyView(LiveActivityScreen(status: .waiting)) },
    Screen(name: "live-activity-waiting-largest-text") {
      AnyView(LiveActivityScreen(status: .waiting).environment(\.dynamicTypeSize, .accessibility5))
    },
    // Northwest is the widest direction, which sets the reading's size for every direction.
    Screen(name: "live-activity-widest-reading") { AnyView(LiveActivityScreen(bearing: 315)) },
    Screen(name: "live-activity-widest-reading-largest-text") {
      AnyView(
        LiveActivityScreen(bearing: 315)
          .environment(\.dynamicTypeSize, .accessibility5)
          .environment(\.legibilityWeight, .bold))
    },
    // When the whole reading doesn't fit, the field the When Only One Fits setting keeps shows.
    Screen(name: "live-activity-widest-reading-keeps-direction-largest-text") {
      AnyView(
        LiveActivityScreen(bearing: 315, shortReadout: .direction)
          .environment(\.dynamicTypeSize, .accessibility5)
          .environment(\.legibilityWeight, .bold))
    },
    Screen(name: "live-activity-status") { AnyView(LiveActivityScreen(status: .slow)) },
    // The longest status, and the one that ends in an ellipsis.
    Screen(name: "live-activity-status-largest-text") {
      AnyView(
        LiveActivityScreen(status: .unavailable)
          .environment(\.dynamicTypeSize, .accessibility5)
          .environment(\.legibilityWeight, .bold))
    },
    Screen(name: "live-activity-finding-largest-text") {
      AnyView(
        LiveActivityScreen(status: .unreliable)
          .environment(\.dynamicTypeSize, .accessibility5)
          .environment(\.legibilityWeight, .bold))
    },
    Screen(name: "carplay-dial") { AnyView(CarPlayDialScreen()) },
  ]

  private var directory: URL?
  private var nameFilter: [String] = []
  private var namedScreens: [String] = []
  private var textVariants = [TextVariant.standard]
  private var interfaceStyle = UIUserInterfaceStyle.light
  /// The most captures of one screen that scrolls, counting the first.
  private var maxParts = 1

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["SCREENSHOT_DIRECTORY"], !path.isEmpty else {
      throw XCTSkip("Captured only by scripts/screenshots")
    }
    directory = URL(fileURLWithPath: path, isDirectory: true)
    nameFilter = Self.list(environment["SCREENSHOT_FILTER"])
    namedScreens = Self.list(environment["SCREENSHOT_SCREENS"])
    interfaceStyle = environment["SCREENSHOT_APPEARANCE"] == "dark" ? .dark : .light
    if let parts = environment["SCREENSHOT_MAX_PARTS"], !parts.isEmpty {
      maxParts = try XCTUnwrap(Int(parts), "SCREENSHOT_MAX_PARTS must be a number, not \(parts)")
      XCTAssertGreaterThanOrEqual(maxParts, 1, "SCREENSHOT_MAX_PARTS must be at least 1")
    }
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
        if screen.showsEnd { try await showEnd(in: window) }
        // Every compass screen with CarPlay connected has the button the tip points to, so
        // each either waits for the tip or checks it is gone before capturing.
        if screen.name.hasPrefix("compass-live-activity") {
          try await waitForTip(in: window, shown: screen.showsTip)
        }
        if screen.presentsSheet { try await waitForSheet(in: window) }
        let name = variant.name.isEmpty ? screen.name : screen.name + "-" + variant.name
        try await requestScreenshot(name, in: directory)
        // Still undecided means the prompt hadn't been answered or dismissed when captured.
        if asksForLocation { try requireUndecidedLocation() }
        if screen.capturesScrolledParts && !asksForLocation {
          try await captureParts(of: name, in: window, to: directory)
        }
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

  /// Waits for a sheet to finish presenting, then for its content: the share sheet draws its
  /// activities out of process, a few seconds after the sheet itself is up.
  private func waitForSheet(in window: UIWindow) async throws {
    struct SheetNotPresented: Error {}
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      var top = window.rootViewController
      while let next = top?.presentedViewController { top = next }
      if let sheet = top, sheet !== window.rootViewController, !sheet.isBeingPresented,
        sheet.view.window != nil, sheet.view.frame.height > 0, holdsShareSheet(sheet)
      {
        try await Task.sleep(for: .seconds(5))
        return
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTFail("The share sheet wasn't presented within 10 seconds")
    throw SheetNotPresented()
  }

  private func holdsShareSheet(_ controller: UIViewController) -> Bool {
    controller is UIActivityViewController || controller.children.contains(where: holdsShareSheet)
  }

  private func onlyForm(in window: UIWindow) throws -> UICollectionView {
    func collections(in view: UIView) -> [UICollectionView] {
      (view as? UICollectionView).map { [$0] }
        ?? view.subviews.flatMap { collections(in: $0) }
    }
    let forms = collections(in: window)
    XCTAssertEqual(forms.count, 1, "Expected one Form to scroll")
    return try XCTUnwrap(forms.first)
  }

  /// Scrolls to the bottom edge and waits until it stays there, since rows the Form sizes as
  /// they appear can change its height after the first scroll.
  private func showEnd(in window: UIWindow) async throws {
    let form = try onlyForm(in: window)
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
      form.layoutIfNeeded()
      form.setContentOffset(
        CGPoint(x: form.contentOffset.x, y: Self.bottomOffset(of: form)), animated: false)
      try await Task.sleep(for: .milliseconds(200))
      form.layoutIfNeeded()
      if abs(form.contentOffset.y - Self.bottomOffset(of: form)) < 0.5 { return }
    } while ContinuousClock.now < deadline
    struct EndNotVisible: Error {}
    XCTFail("The end of the Form must be on screen before capture")
    throw EndNotVisible()
  }

  /// Less than this much more below the visible area is a Form's trailing spacing or the edge of
  /// a row already shown, which doesn't need another capture.
  private static let minimumOverflow: CGFloat = 24
  /// The share of the visible height each scroll step keeps from the previous part, and the
  /// least it keeps: more than the tour card's 40-point fade, so faded text shows in full next.
  private static let partOverlap: CGFloat = 0.15
  private static let minimumPartOverlap: CGFloat = 48

  private static func bottomOffset(of scroll: UIScrollView) -> CGFloat {
    let inset = scroll.adjustedContentInset
    return max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
  }

  /// The scroll view showing the most of the screen whose content runs past its visible area,
  /// such as a Form or a tour card at the largest text sizes, or nil when everything fits.
  private func overflowingScrollView(in window: UIWindow) -> UIScrollView? {
    func scrollViews(in view: UIView) -> [UIScrollView] {
      guard !view.isHidden, view.alpha > 0 else { return [] }
      let own = (view as? UIScrollView).map { [$0] } ?? []
      return own + view.subviews.flatMap { scrollViews(in: $0) }
    }
    func visibleArea(_ scroll: UIScrollView) -> CGFloat {
      let frame = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
      return frame.isNull ? 0 : frame.width * frame.height
    }
    window.layoutIfNeeded()
    return scrollViews(in: window)
      .filter { scroll in
        !(scroll is UITextView) && scroll.isScrollEnabled && visibleArea(scroll) > 0
          && Self.bottomOffset(of: scroll) - scroll.contentOffset.y > Self.minimumOverflow
      }
      .max { visibleArea($0) < visibleArea($1) }
  }

  /// After a screen's first capture, scrolls its main scroll view by about one visible height at
  /// a time, keeping a little of the previous part, and captures each part as `name-partN` until
  /// the end is on screen or `maxParts` captures are taken.
  private func captureParts(of name: String, in window: UIWindow, to folder: URL) async throws {
    guard maxParts > 1, let scroll = overflowingScrollView(in: window) else { return }
    var part = 1
    while Self.bottomOffset(of: scroll) - scroll.contentOffset.y > Self.minimumOverflow {
      guard part < maxParts else {
        print("Screenshots: \(name) has more below its \(maxParts) parts, which isn't captured")
        return
      }
      let inset = scroll.adjustedContentInset
      let visible = scroll.bounds.height - inset.top - inset.bottom
      let overlap = max(visible * Self.partOverlap, Self.minimumPartOverlap)
      let step = max(1, max(visible - overlap, visible / 2).rounded(.down))
      let start = scroll.contentOffset.y
      // A part is an extra, so one that won't hold still ends this screen's parts, not the run.
      guard await settle(scroll, at: min(start + step, Self.bottomOffset(of: scroll))) else {
        print("Screenshots: part \(part + 1) of \(name) didn't stay in place, so it isn't captured")
        return
      }
      // Content that shrank as it laid out can leave nothing new to show.
      guard scroll.contentOffset.y > start + 0.5 else { return }
      part += 1
      try await requestScreenshot("\(name)-part\(part)", in: folder)
    }
  }

  /// Scrolls to an offset and waits until it stays there, since rows the Form sizes as they
  /// appear can change its height, and so its end, after the scroll. False if it never does.
  private func settle(_ scroll: UIScrollView, at offset: CGFloat) async -> Bool {
    var target = offset
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
      scroll.layoutIfNeeded()
      target = min(target, Self.bottomOffset(of: scroll))
      scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
      // Long enough for new rows to lay out and a fade at the edge to follow the scroll.
      // A cancelled test stops here rather than spinning until the deadline.
      guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return false }
      scroll.layoutIfNeeded()
      let stayed = abs(scroll.contentOffset.y - target) < 0.5
      if stayed && target <= Self.bottomOffset(of: scroll) + 0.5 { return true }
    } while ContinuousClock.now < deadline
    return false
  }

  /// TipKit decides whether to show a tip asynchronously, so a tip invalidated just before its
  /// screen appears could still pop up. Waits until the tip's popover is presented, or until it
  /// is not, so every capture of a screen agrees.
  private func waitForTip(in window: UIWindow, shown: Bool) async throws {
    struct TipNotSettled: Error {}
    // A popover tip is a popover presentation from the hosting controller.
    func presentedTip() -> Bool {
      guard let root = window.rootViewController, let presented = root.presentedViewController,
        presented.popoverPresentationController != nil
      else { return false }
      return !presented.isBeingPresented && !presented.isBeingDismissed
        && presented.view.window != nil
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if presentedTip() == shown {
        // Lets the popover's own appearance finish drawing.
        try await Task.sleep(for: .seconds(1))
        if presentedTip() == shown { return }
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    let presented = window.rootViewController?.presentedViewController
    XCTFail(
      (shown ? "The tip wasn't shown within 10 seconds" : "The tip was still shown")
        + "; presented: \(presented.map { String(describing: type(of: $0)) } ?? "nothing")")
    throw TipNotSettled()
  }

  private func showLastRow(in window: UIWindow) async throws {
    let form = try onlyForm(in: window)
    form.layoutIfNeeded()
    let section = try XCTUnwrap((0..<form.numberOfSections).last)
    let item = try XCTUnwrap((0..<form.numberOfItems(inSection: section)).last)
    let lastRow = IndexPath(item: item, section: section)
    let deadline = ContinuousClock.now + .seconds(3)
    var seen = ""
    repeat {
      form.scrollToItem(at: lastRow, at: .bottom, animated: false)
      try await Task.sleep(for: .milliseconds(100))
      form.layoutIfNeeded()
      let row = try XCTUnwrap(form.layoutAttributesForItem(at: lastRow))
      // A row aligned to the bottom edge can end a rounding error past it, at fractional
      // offsets, so allow a hundredth of a point.
      let viewport = form.bounds.inset(by: form.adjustedContentInset).insetBy(dx: 0, dy: -0.01)
      let hasCell = form.cellForItem(at: lastRow) != nil
      if hasCell, viewport.contains(row.frame) { return }
      seen =
        "row \(row.frame), viewport \(viewport), offset \(form.contentOffset), "
        + "content \(form.contentSize), insets \(form.adjustedContentInset), cell \(hasCell)"
    } while ContinuousClock.now < deadline
    struct LastRowNotVisible: Error {}
    XCTFail("The reset row must be fully visible before capture; \(seen)")
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
    heading: TestHeadingSensor.Reading? = .northeast,
    location: TravelAuthorization = .authorized,
    tour: OnboardingState.Step? = nil,
    carPlay: CarPlay = .disconnected,
    showsTip: Bool = false,
    inactive: Bool = false,
    showsSettings: Bool = false
  ) async -> AnyView {
    CompassView.makeHeadingController = {
      let sensor = TestHeadingSensor(reading: heading)
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
      let sensor = TestPhoneLocationSensor(authorized: location == .authorized, fix: .applePark)
      let controller = PhoneLocationController(
        sensor: sensor, cityLookup: TestCityLookup(city: "Cupertino, CA"))
      if inactive {
        controller.start()
        sensor.receive?(.location(TestPhoneLocationSensor.Fix.applePark.location(at: .now)))
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
    if !showsTip {
      onboarding.liveActivityTip.invalidate(reason: .actionPerformed)
      // Invalidation reaches TipKit's datastore asynchronously; until it does, the tip can
      // still be shown. A new tip also reads as not shown while it is pending, so wait for the
      // invalidation itself.
      let deadline = ContinuousClock.now + .seconds(5)
      while ContinuousClock.now < deadline {
        if case .invalidated = onboarding.liveActivityTip.status { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
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

  private static func settings(location: TravelAuthorization = .authorized) -> AnyView {
    AnyView(CompassSettingsView(drive: drive(location: location), showTour: {}))
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

  /// The Live Activity settings with their own unsaved choices, standard unless `change` sets them.
  private static func liveActivitySettings(
    _ change: (inout LiveActivityPreferences) -> Void = { _ in }
  ) -> AnyView {
    let store = LiveActivitySettingsStore(defaults: nil)
    store.update(change)
    return AnyView(NavigationStack { LiveActivitySettingsView(store: store) })
  }

  private static func editor(_ option: AppearanceOption) -> AnyView {
    AnyView(
      NavigationStack { AppearanceOptionEditor(surface: nil, option: option, store: .shared) })
  }

  private static func drive(location: TravelAuthorization) -> DriveSessionController {
    DriveSessionController(
      sensor: TestTravelSensor(authorization: location, showsSystemPrompt: true),
      activity: TestActivityPresenter(), clock: TestDriveClock(now: Date()))
  }
}

/// The Lock Screen and CarPlay Live Activity cards as the app renders them, since the
/// simulator can't show a running Live Activity without CarPlay.
private struct LiveActivityScreen: View {
  var mode: ActivityTimestampMode = .time
  var bearing: Double = 47
  var shortReadout = ShortReadout.degrees
  /// Anything but `.usable` shows that status instead of a reading.
  var status: TravelStatus = .usable

  private var state: CompassActivityAttributes.ContentState {
    var appearance = AppearanceValues()
    appearance.lockScreenTimestamp = mode
    appearance.carPlayActivityTimestamp = mode
    appearance.shortReadout = shortReadout
    return .init(
      bearing: status == .usable ? bearing : nil, status: status, sampleTime: sampleTime,
      expiry: nil, appearance: appearance)
  }

  /// The widest text each mode shows, whatever the time of the capture: a time with a two-digit
  /// hour, or a timer past an hour.
  private var sampleTime: Date {
    if mode == .elapsed { return .now.addingTimeInterval(-(3_600 + 2 * 60 + 3)) }
    return Calendar.current.date(bySettingHour: 12, minute: 58, second: 0, of: .now)
      ?? .now.addingTimeInterval(-12)
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
