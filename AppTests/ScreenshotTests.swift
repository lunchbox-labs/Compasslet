import CompassCore
import CoreLocation
import SwiftUI
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
    let content: @MainActor () -> AnyView
  }

  static let screens: [Screen] = [
    Screen(name: "compass") { ScreenshotTests.compass() },
    Screen(name: "compass-large-text") {
      AnyView(ScreenshotTests.compass().environment(\.dynamicTypeSize, .accessibility3))
    },
    Screen(name: "compass-finding-north") { ScreenshotTests.compass(heading: nil) },
    Screen(name: "compass-calibration") { ScreenshotTests.compass(heading: .calibrationNeeded) },
    Screen(name: "compass-location-denied") { ScreenshotTests.compass(location: .denied) },
    Screen(name: "settings") { ScreenshotTests.settings() },
    Screen(name: "settings-bottom") {
      AnyView(ScreenshotTests.settings().defaultScrollAnchor(.bottom))
    },
    Screen(name: "settings-appearance") {
      AnyView(NavigationStack { AppearanceSettingsView() })
    },
    Screen(name: "settings-appearance-global") {
      AnyView(NavigationStack { AppearanceDetailView(surface: nil) })
    },
    Screen(name: "settings-appearance-iphone") {
      AnyView(NavigationStack { AppearanceDetailView(surface: .phone) })
    },
    Screen(name: "settings-appearance-live-activity") {
      AnyView(NavigationStack { AppearanceDetailView(surface: .activity) })
    },
    Screen(name: "settings-appearance-minor-ticks") { ScreenshotTests.editor(.minorTicks) },
    Screen(name: "settings-appearance-cardinal-labels") { ScreenshotTests.editor(.labels) },
    Screen(name: "settings-appearance-rotation") { ScreenshotTests.editor(.rotation) },
    Screen(name: "settings-appearance-reduce-motion") { ScreenshotTests.editor(.reduceMotion) },
    Screen(name: "live-activity") { AnyView(LiveActivityScreen()) },
  ]

  private var directory: URL?
  private var nameFilter: [String] = []
  private var interfaceStyle = UIUserInterfaceStyle.light

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["SCREENSHOT_DIRECTORY"], !path.isEmpty else {
      throw XCTSkip("Captured only by scripts/screenshots")
    }
    directory = URL(fileURLWithPath: path, isDirectory: true)
    nameFilter = (environment["SCREENSHOT_FILTER"] ?? "").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    interfaceStyle = environment["SCREENSHOT_APPEARANCE"] == "dark" ? .dark : .light
  }

  override func tearDown() async throws {
    CompassView.makeHeadingController = { HeadingController(sensor: DeviceHeadingSensor()) }
    CompassView.makeLocationController = { PhoneLocationController() }
  }

  func testCaptureScreens() async throws {
    let directory = try XCTUnwrap(directory)
    let selected = Self.screens.filter { screen in
      nameFilter.isEmpty || nameFilter.contains { screen.name.hasPrefix($0) }
    }
    XCTAssertFalse(selected.isEmpty, "No screen name starts with \(nameFilter)")
    for screen in selected {
      let window = try makeWindow(screen.content())
      // Long enough for the first readings, navigation titles and any appearance animation.
      try await Task.sleep(for: .seconds(2))
      try await requestScreenshot(screen.name, in: directory)
      window.isHidden = true
    }
  }

  private func makeWindow(_ view: AnyView) throws -> UIWindow {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = interfaceStyle
    window.windowLevel = .alert + 1
    // A window outside the app's SwiftUI scene reports itself inactive, which pauses the
    // compass, so the screens render as the active app does.
    window.rootViewController = UIHostingController(
      rootView: view.environment(\.scenePhase, .active))
    window.makeKeyAndVisible()
    return window
  }

  /// The script watches the directory, saves a full simulator screenshot for each request and
  /// then writes a matching `.done` file.
  private func requestScreenshot(_ name: String, in directory: URL) async throws {
    let done = directory.appendingPathComponent("\(name).done")
    try Data().write(to: directory.appendingPathComponent("\(name).request"))
    // Hosted runners can take 20 seconds or more for one simulator screenshot.
    for _ in 0..<600 where !FileManager.default.fileExists(atPath: done.path) {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: done.path), "No screenshot was taken of \(name)")
  }

  private static func compass(
    heading: FixedHeadingSensor.Reading? = .northeast,
    location: FixedTravelSensor.Access = .allowed
  ) -> AnyView {
    CompassView.makeHeadingController = {
      HeadingController(sensor: FixedHeadingSensor(reading: heading))
    }
    CompassView.makeLocationController = {
      PhoneLocationController(
        sensor: FixedPhoneLocationSensor(allowed: location == .allowed),
        cityLookup: FixedCityLookup())
    }
    return AnyView(CompassView(drive: drive(location: location)))
  }

  private static func settings() -> AnyView {
    AnyView(CompassSettingsView(drive: drive(location: .allowed), close: {}))
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
  enum Access { case allowed, denied }

  let access: Access
  var receive: ((TravelSensorEvent) -> Void)?
  var authorization: TravelAuthorization { access == .allowed ? .authorized : .denied }
  var fullAccuracy: Bool { true }
  var servicesEnabled: Bool { true }
  var available: Bool { true }

  init(access: Access) { self.access = access }

  func requestAuthorization() {}
  func start() throws {}
  func stop() {}
}

@MainActor
private final class IdleActivity: CompassActivityPresenting {
  var onDismiss: (() -> Void)?
  var isEnabled: Bool { true }
  func start() async throws {}
  func update(_ presentation: TravelPresentation) async {}
  func end() async {}
}

/// The Lock Screen and CarPlay Live Activity cards as the app renders them, since the
/// simulator can't show a running Live Activity without CarPlay.
private struct LiveActivityScreen: View {
  private let state = CompassActivityAttributes.ContentState(
    bearing: 47, status: .usable, sampleTime: .now.addingTimeInterval(-12), expiry: nil)

  var body: some View {
    VStack(spacing: 32) {
      Spacer()
      card(title: "Lock Screen") {
        CompassActivityCard(state: state)
      }
      card(title: "CarPlay") {
        CompassActivityCard(state: state, isSmall: true).frame(height: 100)
      }
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemGroupedBackground))
  }

  private func card<Content: View>(
    title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      content()
        .frame(maxWidth: 360)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }
  }
}
