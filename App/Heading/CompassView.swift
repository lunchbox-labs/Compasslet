import CompassCore
import SwiftUI
import TipKit
import UIKit

struct CompassView: View {
  /// The screenshot tests replace these with fixed readings; the app always uses the device.
  static var makeHeadingController: @MainActor () -> HeadingController = {
    HeadingController(sensor: DeviceHeadingSensor())
  }
  static var makeLocationController: @MainActor () -> PhoneLocationController = {
    PhoneLocationController()
  }

  @ObservedObject var drive: DriveSessionController
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @StateObject private var compass = CompassView.makeHeadingController()
  @StateObject private var location = CompassView.makeLocationController()
  @ObservedObject private var appearanceStore = AppearanceStore.shared
  @StateObject private var onboarding: OnboardingState
  @State private var showingSettings: Bool
  /// True from opening Settings until its sheet has fully gone, unlike `showingSettings`, which
  /// turns false as the sheet starts to close.
  @State private var settingsOnScreen: Bool
  /// Whether the gear opened Settings, so VoiceOver focus goes back to it afterwards.
  @State private var settingsOpenedFromGear = false
  /// Set when Settings asks for the tour, which starts once the sheet has gone.
  @State private var tourAfterSettings = false
  @State private var showingHeadingStatus = false
  /// The main screen's side margin, also subtracted when measuring its text.
  private let contentMargin: CGFloat = 24
  @State private var debugEnabled = false
  @State private var showingLiveActivityFailure = false
  /// The Live Activity button's frame in global coordinates, for the tour's spotlight.
  @State private var liveActivityButtonFrame: CGRect?
  @ScaledMetric(relativeTo: .body) private var compactStatusSize = 17
  @ScaledMetric(relativeTo: .body) private var floatingControlDiameter: CGFloat = 52
  @AccessibilityFocusState private var settingsButtonFocused: Bool
  @Namespace private var glassNamespace

  init(
    drive: DriveSessionController,
    onboarding: @autoclosure @escaping () -> OnboardingState = OnboardingState(),
    // Only the screenshots open the screen with Settings already presented.
    showingSettings: Bool = false
  ) {
    self.drive = drive
    _onboarding = StateObject(wrappedValue: onboarding())
    _showingSettings = State(initialValue: showingSettings)
    _settingsOnScreen = State(initialValue: showingSettings)
  }

  private var storedAppearance: AppearanceValues {
    appearanceStore.preferences.effective(for: .phone)
  }
  /// Reduce Motion replaces the rotating dial with steady text unless Appearance keeps the dial.
  private var steadyReading: Bool {
    reduceMotion && storedAppearance.reducedMotionDial == .steadyReadout
  }
  private var appearance: AppearanceValues {
    steadyReading ? storedAppearance.requiringReadout() : storedAppearance
  }
  /// Only a rotating dial shown under Reduce Motion steps; steady text keeps smoothed headings.
  private var stepsHeading: Bool { reduceMotion && !steadyReading }
  private var roundedDegrees: Int? {
    compass.sample.map { Int($0.angle.degrees.rounded()) % 360 }
  }
  private var accessibilitySummary: String {
    guard let sample = compass.sample, let roundedDegrees else { return compass.status.title }
    let direction = CompassPoint(angle: sample.angle).name
    let prefix = compass.status == .inactive ? "Last reading. " : ""
    return
      "\(prefix)\(roundedDegrees) degrees, \(direction), magnetic heading. Accuracy plus or minus \(Int(min(sample.accuracyDegrees, 360).rounded())) degrees."
  }

  var body: some View {
    NavigationStack {
      compassScreen
        .navigationTitle("Compasslet")
        .navigationBarTitleDisplayMode(.inline)
    }
    // The title is in the navigation bar, outside the compass, so the tour hides both.
    .allowsHitTesting(!onboarding.isTouring)
    .accessibilityHidden(onboarding.isTouring)
    .overlay {
      // Over the navigation bar too, so the tour dims the whole screen.
      GeometryReader { overlay in
        let origin = overlay.frame(in: .global).origin
        WelcomeTourOverlay(
          onboarding: onboarding,
          buttonFrame: liveActivityButtonFrame?.offsetBy(dx: -origin.x, dy: -origin.y),
          carPlayConnected: carPlayReady)
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: onboarding.step)
    }
    .sheet(isPresented: $showingSettings, onDismiss: settingsDismissed) {
      CompassSettingsView(drive: drive, showTour: replayTour)
        .modifier(AppThemeModifier(store: .shared))
        .tint(Color.accentColor)
        .navigationTransition(.zoom(sourceID: SettingsTransition.source, in: glassNamespace))
    }
  }

  private var compassScreen: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        GeometryReader { content in
          let textWidth = (content.size.width - 2 * contentMargin).rounded(.down)
          let sideDial = min(content.size.height - 24, content.size.width * 0.42).rounded(.down)
          ViewThatFits(in: [.horizontal, .vertical]) {
            if content.size.width > content.size.height {
              HStack(spacing: 24) {
                dial(size: sideDial)
                information(details: true, width: textWidth - sideDial - 24)
              }
              .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 24) {
              dial(size: min(textWidth, content.size.height * 0.45))
              information(details: true, width: textWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
              dial(size: min(160, content.size.height * 0.25))
              information(details: false, width: textWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            information(details: false, width: textWidth)
              .fixedSize(horizontal: false, vertical: true)
            // At extreme text sizes, keep the reading or critical status readable.
            // Location preferences remain available in the scrollable Settings.
            // This last layout is the one place the main screen limits the user's size: the
            // reading is capped to the screen so it stays whole rather than clipped, which
            // is a deliberate non-scrolling design choice rather than a Dynamic Type gap.
            essentialReading(height: content.size.height)
          }
          .padding(.horizontal, contentMargin)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Measured below the 44pt navigation bar, so the same phones count as short as when
        // the whole screen was measured against 700pt.
        floatingControls(compact: geometry.size.height < 656)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .background(Color(uiColor: .systemBackground))
    .task(id: scenePhase) {
      guard scenePhase == .active else {
        compass.stop(preservingLastReading: true)
        location.stop(preservingLastReading: true)
        return
      }
      // The phone readouts don't depend on ending leftover Live Activities, so the sensors
      // start without waiting for it. Cleanup still runs if this task is already cancelled.
      // The location prompt waits for the first-launch tour so it doesn't cover it.
      async let activation: Void = drive.phoneBecameActive(
        requestingPermission: !onboarding.isTouring)
      guard !Task.isCancelled else { return }
      compass.setReducedMotion(stepsHeading)
      async let heading: Void = compass.run(preservingLastReadingOnStop: true)
      async let phoneLocation: Void = location.run(preservingLastReadingOnStop: true)
      while !Task.isCancelled {
        debugEnabled = (try? CompassDiagnostics.shared?.isEnabled()) ?? false
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
      _ = await activation
      _ = await heading
      _ = await phoneLocation
    }
    .alert(compass.status.title, isPresented: $showingHeadingStatus) {
      if compass.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
        Button("Open Settings") { openURL(url) }
      }
      Button("OK", role: .cancel) {}
    } message: {
      Text(compass.status.detail)
    }
    .onChange(of: stepsHeading) { _, value in compass.setReducedMotion(value) }
    .onChange(of: onboarding.isTouring) { _, touring in
      guard !touring else { return }
      settingsButtonFocused = true
      drive.requestPhoneAuthorization(isForeground: scenePhase == .active)
    }
  }

  private var carPlayReady: Bool { drive.isCarPlayConnected && drive.setupStatus == .ready }

  /// The tour shows the button for its step without CarPlay. When the step ends, the button
  /// merges back into the gear, which keeps its place, so nothing else moves.
  private var tourShowsLiveActivityControl: Bool { onboarding.step == .liveActivity }

  /// The screen's floating controls on glass in the bottom-right corner: Settings, and the
  /// Live Activity button beside it while CarPlay is connected. One glass container, so the
  /// two render as a group and the button can appear and leave beside the gear.
  private func floatingControls(compact: Bool) -> some View {
    // Capped below the guide's 80pt so the row leaves the compass room at the largest text
    // sizes; the large content viewer shows each control's name instead.
    let diameter = max(44, min(compact ? floatingControlDiameter - 8 : floatingControlDiameter, 60))
    return HStack {
      Spacer(minLength: 0)
      GlassEffectContainer(spacing: 12) {
        HStack(spacing: 12) {
          if carPlayReady || tourShowsLiveActivityControl {
            liveActivityButton(diameter: diameter)
          }
          settingsButton(diameter: diameter)
        }
      }
      .animation(reduceMotion ? nil : .smooth, value: carPlayReady)
    }
    .padding(.horizontal, 16).padding(.bottom, 8)
  }

  private func settingsButton(diameter: CGFloat) -> some View {
    Button {
      settingsOpenedFromGear = true
      openSettings()
    } label: {
      FloatingControlLabel(
        systemImage: "gear", diameter: diameter, glassID: SettingsTransition.source,
        namespace: glassNamespace)
    }
    .buttonStyle(FloatingControlStyle())
    .matchedTransitionSource(id: SettingsTransition.source, in: glassNamespace)
    .accessibilityLabel("Settings")
    .accessibilityShowsLargeContentViewer {
      Label("Settings", systemImage: "gear")
    }
    .accessibilityFocused($settingsButtonFocused)
  }

  /// The manual fallback for the automatic CarPlay start, shown while CarPlay is connected.
  private func liveActivityButton(diameter: CGFloat) -> some View {
    Button(action: toggleLiveActivity) {
      FloatingControlLabel(
        systemImage: liveActivitySymbol, diameter: diameter, glassID: "liveActivity",
        namespace: glassNamespace)
    }
    .buttonStyle(FloatingControlStyle())
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: {
      liveActivityButtonFrame = $0
    }
    .onDisappear { liveActivityButtonFrame = nil }
    .popoverTip(
      carPlayReady && !onboarding.isTouring && !settingsOnScreen
        ? onboarding.liveActivityTip : nil,
      arrowEdge: .bottom
    )
    .accessibilityLabel(liveActivityAction)
    .accessibilityHint(liveActivityHint)
    .accessibilityShowsLargeContentViewer {
      Label(liveActivityAction, systemImage: liveActivitySymbol)
    }
    .alert("Live Activity Couldn’t Start", isPresented: $showingLiveActivityFailure) {
      if let url = URL(string: UIApplication.openSettingsURLString) {
        Button("Open Settings") { openURL(url) }
      }
      Button("OK", role: .cancel) {}
    } message: {
      Text("Make sure Live Activities are allowed for Compasslet in the Settings app.")
    }
  }

  /// A drive whose Live Activity was dismissed or couldn't start offers to start it again.
  private var liveActivityRunning: Bool {
    drive.isDriving && drive.compactStatus != .dismissed && drive.compactStatus != .unavailable
  }

  private var liveActivityAction: String {
    liveActivityRunning ? "End Live Activity" : "Start Live Activity"
  }

  private var liveActivitySymbol: String { liveActivityRunning ? "stop.fill" : "play.fill" }

  private var liveActivityHint: String {
    guard liveActivityRunning else { return "Shows your travel direction on the Lock Screen" }
    return
      "Stops travel direction and location use until you start it again or reopen Compasslet on CarPlay"
  }

  private func toggleLiveActivity() {
    onboarding.liveActivityTip.invalidate(reason: .actionPerformed)
    let running = liveActivityRunning
    Task {
      if running {
        await drive.endLiveActivity()
        AccessibilityNotification.Announcement("Live Activity ended").post()
      } else {
        await drive.startLiveActivity()
        guard drive.isDriving else { return }
        switch drive.compactStatus {
        case .unavailable: showingLiveActivityFailure = true
        case .active: AccessibilityNotification.Announcement("Live Activity started").post()
        case .starting: AccessibilityNotification.Announcement("Live Activity starting").post()
        case .inactive, .dismissed: break
        }
      }
    }
  }

  /// The readout keeps its one-line width, so a reading too wide for the screen still moves to
  /// a smaller layout. The text below it is measured at `width` instead: `ViewThatFits` compares
  /// ideal sizes, and a sentence's ideal width is one unbroken line, which would otherwise push
  /// a long status hint into the small-dial layout without its hint. `width` must not exceed the
  /// width `ViewThatFits` offers, or every layout but the last fails to fit.
  private func information(details: Bool, width: CGFloat) -> some View {
    VStack(spacing: details ? 16 : 8) {
      if compass.sample != nil, appearance.hasReadout { phoneReadout }
      statusAndLocation(details: details)
        .frame(idealWidth: max(0, width), maxWidth: .infinity)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }

  private func statusAndLocation(details: Bool) -> some View {
    VStack(spacing: details ? 16 : 8) {
      if let sample = compass.sample {
        // The readout already speaks its accuracy. With both center readouts hidden,
        // this line becomes the single VoiceOver stop for the heading instead.
        Text(
          "\(compass.status == .inactive ? "Last reading · " : "")Accuracy ±\(Int(min(sample.accuracyDegrees, 360).rounded()))°"
        )
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityHidden(appearance.hasReadout)
        .accessibilityLabel(accessibilitySummary)
        if steadyReading {
          Text("Dial hidden while Reduce Motion is on")
            .font(.caption2).foregroundStyle(.secondary)
        }
      } else {
        if details {
          Text(compass.status.title).font(.headline)
          Text(compass.status.detail).foregroundStyle(.primary)
        } else {
          // Without room for the hint, the title opens it, as in the last layout.
          Button(action: { showingHeadingStatus = true }) {
            Text(compass.status.title).font(.headline)
          }
          .frame(minHeight: 44)
          .accessibilityHint("Shows heading status and available recovery actions")
        }
        if compass.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
          // Links draw in the system blue (4.0:1 on white), not the accent, unless told.
          Link("Open Settings", destination: url).foregroundStyle(.tint).frame(minHeight: 44)
        }
      }
      if details {
        PhoneLocationReadout(location: location)
      }
      if let notice = locationNotice {
        Button(notice) { openSettings() }.font(.subheadline).frame(minHeight: 44)
      }
      if debugEnabled, details, let sample = compass.sample {
        Text("Debug · Sample \(sample.timestamp.formatted(date: .omitted, time: .standard))")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private func essentialReading(height: CGFloat) -> some View {
    VStack(spacing: 8) {
      if compass.sample != nil {
        if compass.status == .inactive {
          Text("Last reading").font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        GeometryReader { available in
          PhoneCompassReadout(
            bearing: compass.sample?.angle.degrees ?? 0, appearance: appearance,
            maximumTextSize: max(17, min(available.size.height / 2.5, available.size.width / 2.8))
          )
          .dynamicTypeSize(appearance.readoutTextSize(system: dynamicTypeSize))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(accessibilitySummary)
        }
      } else {
        Button(action: { showingHeadingStatus = true }) {
          Text(compactHeadingStatus).multilineTextAlignment(.center)
        }
        .frame(minHeight: 44)
        .accessibilityLabel(compass.status.title)
        .accessibilityHint("Shows heading status and available recovery actions")
      }
      if let notice = locationNotice {
        Button(action: { openSettings() }) {
          Text(compactLocationStatus).multilineTextAlignment(.center)
        }
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .accessibilityLabel(notice)
      }
    }
    // A readable compact status is the last resort, rather than clipping a
    // full explanation. Settings retains unrestricted Dynamic Type details.
    .font(.system(size: min(compactStatusSize, max(17, height / 6))))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var compactHeadingStatus: String {
    switch compass.status {
    case .inactive: "Compass paused"
    case .waiting: "Finding north…"
    case .live: "Magnetic north"
    case .stale: "Heading stale"
    case .calibration: "Calibrate compass"
    case .unavailable: "Compass unavailable"
    case .denied: "Heading access denied"
    case .interrupted: "Heading interrupted"
    }
  }

  private var compactLocationStatus: String {
    switch drive.setupStatus {
    case .ready: "Location Enabled"
    case .permissionRequired: "Enable Location"
    case .denied: "Location denied"
    case .restricted: "Location restricted"
    case .servicesDisabled: "Location Services off"
    case .preciseLocationRequired: "Approximate location"
    case .unavailable: "CarPlay unavailable"
    }
  }

  private var phoneReadout: some View {
    PhoneCompassReadout(bearing: compass.sample?.angle.degrees ?? 0, appearance: appearance)
      .dynamicTypeSize(appearance.readoutTextSize(system: dynamicTypeSize))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilitySummary)
  }

  // The dial repeats the readout visually; VoiceOver gets one heading stop from the text.
  @ViewBuilder private func dial(size: CGFloat) -> some View {
    if !steadyReading {
      CompassDial(
        bearing: compass.sample?.angle.degrees, appearance: appearance, showsReadout: false
      )
      .frame(width: max(0, size), height: max(0, size))
      .accessibilityHidden(true)
    }
  }

  private var locationNotice: String? {
    switch drive.setupStatus {
    case .ready: nil
    case .permissionRequired: "Enable Location"
    case .denied: "Location access denied"
    case .restricted: "Location access is restricted"
    case .servicesDisabled: "Location Services is off"
    case .preciseLocationRequired: "Approximate location · Enable Precise Location"
    case .unavailable: "CarPlay travel direction unavailable"
    }
  }

  private func openSettings() {
    settingsOnScreen = true
    showingSettings = true
  }

  /// Settings closes first, so the tour doesn't start under the sheet.
  private func replayTour() {
    tourAfterSettings = true
    showingSettings = false
  }

  private func settingsDismissed() {
    settingsOnScreen = false
    let fromGear = settingsOpenedFromGear
    settingsOpenedFromGear = false
    if tourAfterSettings {
      tourAfterSettings = false
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { onboarding.replay() }
    } else if fromGear {
      settingsButtonFocused = true
    }
  }
}

private enum SettingsTransition {
  static let source = "settings"
}

/// An icon-only circle on regular glass, sized by the caller within 44 to 80 points.
private struct FloatingControlLabel: View {
  let systemImage: String
  let diameter: CGFloat
  let glassID: String
  let namespace: Namespace.ID

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: diameter * 0.38, weight: .semibold))
      .foregroundStyle(.primary)
      .frame(width: diameter, height: diameter)
      // The glass is the control's only surface; anything drawn under it hides the glass.
      .glassEffect(.regular.interactive(), in: .circle)
      .glassEffectID(glassID, in: namespace)
      .contentShape(.circle)
  }
}

/// Leaves the press feedback to the interactive glass, which flexes under a finger, rather
/// than also dimming the label as the plain style does.
private struct FloatingControlStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

struct PhoneCompassReadout: View {
  let bearing: Double
  let appearance: AppearanceValues
  var maximumTextSize: CGFloat = .infinity
  @ScaledMetric(relativeTo: .largeTitle) private var textSize = 60

  var body: some View {
    VStack(spacing: 0) {
      if appearance.showDirection {
        Text(CompassPoint(degrees: bearing)?.abbreviation ?? "—")
      }
      if appearance.showDegrees {
        Text("\(Int(bearing.rounded()) % 360)°").monospacedDigit()
      }
    }
    .font(.system(size: min(textSize, maximumTextSize), weight: .light))
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: true)
  }
}
