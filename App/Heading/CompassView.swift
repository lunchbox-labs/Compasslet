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

  let drive: DriveSessionController
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// Only the dial, readout and accuracy views read its sample, so heading-rate updates redraw
  /// them without the screen around them.
  @State private var compass = CompassView.makeHeadingController()
  @State private var location = CompassView.makeLocationController()
  private let appearanceStore = AppearanceStore.shared
  @State private var onboarding: OnboardingState
  @State private var showingSettings: Bool
  /// True from opening Settings until its sheet has fully gone, unlike `showingSettings`, which
  /// turns false as the sheet starts to close.
  @State private var settingsOnScreen: Bool
  /// Whether the gear opened Settings, so VoiceOver focus goes back to it afterwards.
  @State private var settingsOpenedFromGear = false
  /// Set when Settings asks for the tour, which starts once the sheet has gone.
  @State private var tourAfterSettings = false
  @State private var showingHeadingStatus = false
  @State private var showingLiveActivityFailure = false
  /// The Live Activity button's frame in global coordinates, for the tour's spotlight.
  @State private var liveActivityButtonFrame: CGRect?
  @ScaledMetric(relativeTo: .body) private var compactStatusSize = 17
  @ScaledMetric(relativeTo: .body) private var floatingControlDiameter: CGFloat = 52
  @AccessibilityFocusState private var settingsButtonFocused: Bool
  @Namespace private var glassNamespace

  init(
    drive: DriveSessionController,
    onboarding: OnboardingState = OnboardingState(),
    // Only the screenshots open the screen with Settings already presented.
    showingSettings: Bool = false
  ) {
    self.drive = drive
    _onboarding = State(initialValue: onboarding)
    _showingSettings = State(initialValue: showingSettings)
    _settingsOnScreen = State(initialValue: showingSettings)
  }

  /// Reduce Motion replaces the rotating dial with steady text unless Appearance keeps the dial.
  private var presentation: PhoneCompassPresentation {
    PhoneCompassPresentation(
      appearance: appearanceStore.preferences.effective(for: .phone), reduceMotion: reduceMotion)
  }
  private var appearance: AppearanceValues { presentation.appearance }
  /// Only a rotating dial shown under Reduce Motion steps; steady text keeps smoothed headings.
  private var stepsHeading: Bool { reduceMotion && presentation.showsDial }
  /// The readout's text size, from the system's and the Appearance setting.
  private var readoutTextSize: DynamicTypeSize {
    appearance.readoutTextSize(system: dynamicTypeSize)
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

  /// The system's side margin, matching UIKit's minimum layout margins and the Settings list
  /// insets: 20pt on iPhones at least 414pt wide, 16pt on the rest.
  private static func sideMargin(forWidth width: CGFloat) -> CGFloat { width >= 414 ? 20 : 16 }

  private var compassScreen: some View {
    GeometryReader { geometry in
      // Also subtracted when measuring the text, and shared with the floating controls.
      let margin = Self.sideMargin(forWidth: geometry.size.width)
      VStack(spacing: 0) {
        GeometryReader { content in
          let textWidth = (content.size.width - 2 * margin).rounded(.down)
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
          .padding(.horizontal, margin)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Measured below the 44pt navigation bar, so the same phones count as short as when
        // the whole screen was measured against 700pt.
        floatingControls(compact: geometry.size.height < 656, margin: margin)
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

  /// Car audio counts too, because a CarPlay automation can start a drive without
  /// Compasslet's CarPlay scene.
  private var carPlayReady: Bool {
    (drive.isCarPlayConnected || drive.isCarAudioConnected) && drive.setupStatus == .ready
  }

  /// The tour shows the button for its step without CarPlay. When the step ends, the button
  /// merges back into the gear, which keeps its place, so nothing else moves.
  private var tourShowsLiveActivityControl: Bool { onboarding.step == .liveActivity }

  /// The screen's floating controls on glass in the bottom-right corner: Settings, and the
  /// Live Activity button beside it while CarPlay is connected. One glass container, so the
  /// two render as a group and the button can appear and leave beside the gear.
  private func floatingControls(compact: Bool, margin: CGFloat) -> some View {
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
    .padding(.horizontal, margin).padding(.bottom, 8)
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
    // Opaque, like the welcome tour's cards: the default material lets the large heading show
    // through behind the tip's text.
    .tipBackground(Color(uiColor: .secondarySystemGroupedBackground))
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
  private var liveActivityRunning: Bool { drive.isLiveActivityRunning }

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
      if compass.hasSample, appearance.hasReadout {
        HeadingReadout(compass: compass, appearance: appearance, textSize: readoutTextSize)
      }
      statusAndLocation(details: details)
        .frame(idealWidth: max(0, width), maxWidth: .infinity)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }

  private func statusAndLocation(details: Bool) -> some View {
    VStack(spacing: details ? 16 : 8) {
      if compass.hasSample {
        // The readout already speaks its accuracy. With both center readouts hidden,
        // this line becomes the single VoiceOver stop for the heading instead.
        HeadingAccuracy(compass: compass, hiddenFromVoiceOver: appearance.hasReadout)
        if !presentation.showsDial {
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
      if let notice = drive.setupStatus.notice {
        Button(notice) { locationNoticeTapped() }.font(.subheadline).frame(minHeight: 44)
      }
      if details, compass.hasSample, CompassDiagnostics.shared?.isEnabled == true {
        HeadingSampleTime(compass: compass)
      }
    }
  }

  private func essentialReading(height: CGFloat) -> some View {
    VStack(spacing: 8) {
      if compass.hasSample {
        if compass.status == .inactive {
          Text("Last reading").font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        GeometryReader { available in
          HeadingReadout(
            compass: compass, appearance: appearance, textSize: readoutTextSize,
            filling: max(17, min(available.size.height / 2.5, available.size.width / 2.8)))
        }
      } else {
        Button(action: { showingHeadingStatus = true }) {
          Text(compass.status.compactTitle).multilineTextAlignment(.center)
        }
        .frame(minHeight: 44)
        .accessibilityLabel(compass.status.title)
        .accessibilityHint("Shows heading status and available recovery actions")
      }
      if let notice = drive.setupStatus.notice {
        Button(action: { locationNoticeTapped() }) {
          Text(drive.setupStatus.compactNotice).multilineTextAlignment(.center)
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

  // The dial repeats the readout visually; VoiceOver gets one heading stop from the text.
  @ViewBuilder private func dial(size: CGFloat) -> some View {
    if presentation.showsDial {
      HeadingDial(compass: compass, appearance: appearance)
        .frame(width: max(0, size), height: max(0, size))
        .accessibilityHidden(true)
    }
  }

  /// Undecided permission asks for location right away; anything else needs Settings.
  private func locationNoticeTapped() {
    if drive.setupStatus == .permissionRequired {
      drive.askForLocationPermission()
    } else {
      openSettings()
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

extension HeadingController {
  /// What VoiceOver reads for the heading, or the status without a reading.
  fileprivate var accessibilitySummary: String {
    guard let sample else { return status.title }
    let degrees = sample.angle.roundedDegrees
    let direction = CompassPoint(angle: sample.angle).name
    let prefix = status == .inactive ? "Last reading. " : ""
    return
      "\(prefix)\(degrees) degrees, \(direction), magnetic heading. Accuracy plus or minus \(Int(min(sample.accuracyDegrees, 360).rounded())) degrees."
  }
}

// The views below read the heading's sample, so its updates redraw only them.

/// The rotating dial. It repeats the readout visually, so the caller hides it from VoiceOver.
private struct HeadingDial: View {
  let compass: HeadingController
  let appearance: AppearanceValues

  var body: some View {
    CompassDial(bearing: compass.sample?.angle.degrees, appearance: appearance)
  }
}

/// The large reading, one VoiceOver stop for the whole heading. With `filling`, it caps its text
/// at that size and fills the space offered, as the last-resort layout needs.
private struct HeadingReadout: View {
  let compass: HeadingController
  let appearance: AppearanceValues
  let textSize: DynamicTypeSize
  var filling: CGFloat?

  var body: some View {
    if let filling {
      reading(maximumTextSize: filling)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compass.accessibilitySummary)
    } else {
      reading(maximumTextSize: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compass.accessibilitySummary)
    }
  }

  private func reading(maximumTextSize: CGFloat) -> some View {
    PhoneCompassReadout(
      bearing: compass.sample?.angle.degrees ?? 0, appearance: appearance,
      maximumTextSize: maximumTextSize
    )
    .dynamicTypeSize(textSize)
  }
}

/// The reading's accuracy, and the heading's VoiceOver stop when no readout shows.
private struct HeadingAccuracy: View {
  let compass: HeadingController
  let hiddenFromVoiceOver: Bool

  var body: some View {
    if let sample = compass.sample {
      Text(
        "\(compass.status == .inactive ? "Last reading · " : "")Accuracy ±\(Int(min(sample.accuracyDegrees, 360).rounded()))°"
      )
      .font(.subheadline).foregroundStyle(.secondary)
      .accessibilityHidden(hiddenFromVoiceOver)
      .accessibilityLabel(compass.accessibilitySummary)
    }
  }
}

/// When the shown sample was taken, while diagnostics are on.
private struct HeadingSampleTime: View {
  let compass: HeadingController

  var body: some View {
    if let sample = compass.sample {
      Text("Debug · Sample \(sample.timestamp.formatted(date: .omitted, time: .standard))")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }
}

private enum SettingsTransition {
  static let source = "settings"
}

/// An icon-only circle on regular glass, sized by the caller within 44 to 60 points.
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

/// The phone's large reading, in the bold SF Pro Rounded display voice that the organisation's
/// iOS guide gives brand moments.
struct PhoneCompassReadout: View {
  let bearing: Double
  let appearance: AppearanceValues
  var maximumTextSize: CGFloat = .infinity
  @ScaledMetric(relativeTo: .largeTitle) private var textSize = 60

  private var angle: CompassAngle? { CompassAngle(degrees: bearing) }

  var body: some View {
    VStack(spacing: 0) {
      if appearance.showDirection {
        Text(angle.map { CompassPoint(angle: $0).abbreviation } ?? "—")
      }
      if appearance.showDegrees {
        Text(angle.map { "\($0.roundedDegrees)°" } ?? "—").monospacedDigit()
      }
    }
    .font(.system(size: min(textSize, maximumTextSize), weight: .bold, design: .rounded))
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: true)
  }
}
