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
  @State private var showingSettings = false
  @State private var showingHeadingStatus = false
  @State private var debugEnabled = false
  @State private var showingLiveActivityFailure = false
  @ScaledMetric(relativeTo: .body) private var compactStatusSize = 17
  @ScaledMetric(relativeTo: .body) private var liveActivityDiameter: CGFloat = 52
  @AccessibilityFocusState private var menuFocused: Bool

  init(
    drive: DriveSessionController,
    onboarding: @autoclosure @escaping () -> OnboardingState = OnboardingState()
  ) {
    self.drive = drive
    _onboarding = StateObject(wrappedValue: onboarding())
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
    return
      "\(roundedDegrees) degrees, \(direction), magnetic heading. Accuracy plus or minus \(Int(min(sample.accuracyDegrees, 360).rounded())) degrees."
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        VStack(spacing: 0) {
          header
          GeometryReader { content in
            ViewThatFits(in: [.horizontal, .vertical]) {
              if content.size.width > content.size.height {
                HStack(spacing: 24) {
                  dial(size: min(content.size.height - 24, content.size.width * 0.42))
                  information(details: true)
                }
                .fixedSize(horizontal: false, vertical: true)
              }
              VStack(spacing: 24) {
                dial(size: min(content.size.width - 48, content.size.height * 0.45))
                information(details: true)
              }
              .fixedSize(horizontal: false, vertical: true)
              VStack(spacing: 12) {
                dial(size: min(160, content.size.height * 0.25))
                information(details: false)
              }
              .fixedSize(horizontal: false, vertical: true)
              information(details: false)
                .fixedSize(horizontal: false, vertical: true)
              // At extreme text sizes, keep the reading or critical status readable.
              // Location preferences remain available in the scrollable Settings.
              // This last layout is the one place the main screen limits the user's size: the
              // reading is capped to the screen so it stays whole rather than clipped, which
              // is a deliberate non-scrolling design choice rather than a Dynamic Type gap.
              essentialReading(height: content.size.height)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          liveActivityControl(compact: geometry.size.height < 700)
        }
        .allowsHitTesting(!showingSettings && !onboarding.isTouring)
        .accessibilityHidden(showingSettings || onboarding.isTouring)
        .contentShape(Rectangle())
        .simultaneousGesture(
          DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
              guard value.startLocation.x <= 24, value.translation.width > 60,
                abs(value.translation.height) < value.translation.width / 2
              else { return }
              openSettings()
            }
        )
        if showingSettings {
          CompassSettingsView(
            drive: drive, close: closeSettings, showTour: replayTour
          )
          .frame(width: geometry.size.width, height: geometry.size.height)
          .gesture(SettingsDismissGesture(close: closeSettings))
          .accessibilityAddTraits(.isModal)
          .accessibilityAction(.escape, closeSettings)
          .transition(reduceMotion ? .opacity : .move(edge: .leading))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .overlayPreferenceValue(LiveActivityControlBoundsKey.self) { anchor in
        GeometryReader { overlay in
          WelcomeTourOverlay(
            onboarding: onboarding, buttonFrame: anchor.map { overlay[$0] },
            carPlayConnected: carPlayReady)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: onboarding.step)
      }
    }
    .background(Color(uiColor: .systemBackground))
    .task(id: scenePhase) {
      guard scenePhase == .active else {
        compass.stop()
        location.stop()
        return
      }
      // The phone readouts don't depend on ending leftover Live Activities, so the sensors
      // start without waiting for it. Cleanup still runs if this task is already cancelled.
      // The location prompt waits for the first-launch tour so it doesn't cover it.
      async let activation: Void = drive.phoneBecameActive(
        requestingPermission: !onboarding.isTouring)
      guard !Task.isCancelled else { return }
      compass.setReducedMotion(stepsHeading)
      async let heading: Void = compass.run()
      async let phoneLocation: Void = location.run()
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
      menuFocused = true
      drive.requestPhoneAuthorization(isForeground: scenePhase == .active)
    }
  }

  private var header: some View {
    HStack {
      Button(action: { openSettings() }) {
        Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
          .foregroundStyle(Color.primary)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Settings")
      .accessibilityFocused($menuFocused)
      Spacer(minLength: 8)
      Text("Compasslet").font(.headline)
      Spacer(minLength: 8)
      Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
  }

  private var carPlayReady: Bool { drive.isCarPlayConnected && drive.setupStatus == .ready }

  /// The tour shows the button in place for its step without CarPlay, then fades it out while
  /// keeping its space, so the compass doesn't jump under the next step.
  private var tourShowsLiveActivityControl: Bool {
    onboarding.step == .liveActivity || onboarding.step == .shortcuts
  }
  private var liveActivityControlFaded: Bool { !carPlayReady && onboarding.step == .shortcuts }

  /// The manual fallback for the automatic CarPlay start, shown while CarPlay is connected.
  /// An icon-only circle in the bottom-right corner, a little smaller on short screens.
  @ViewBuilder private func liveActivityControl(compact: Bool) -> some View {
    if carPlayReady || tourShowsLiveActivityControl {
      let diameter = max(44, min(compact ? liveActivityDiameter - 8 : liveActivityDiameter, 80))
      HStack {
        Spacer(minLength: 0)
        Button(action: toggleLiveActivity) {
          Image(systemName: liveActivitySymbol)
            .font(.system(size: diameter * 0.36, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            // One Liquid Glass circle, without the ring and opaque fill that hid the glass.
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: LiveActivityControlBoundsKey.self, value: .bounds) { $0 }
        .popoverTip(
          carPlayReady && !onboarding.isTouring && !showingSettings
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
      .padding(.horizontal, 16).padding(.bottom, 8)
      .opacity(liveActivityControlFaded ? 0 : 1)
      .accessibilityHidden(liveActivityControlFaded)
      .animation(.easeOut(duration: reduceMotion ? 0.2 : 0.8), value: liveActivityControlFaded)
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

  private func information(details: Bool) -> some View {
    VStack(spacing: details ? 16 : 8) {
      if let sample = compass.sample {
        if appearance.hasReadout { phoneReadout }
        // The readout already speaks its accuracy. With both center readouts hidden,
        // this line becomes the single VoiceOver stop for the heading instead.
        Text("Accuracy ±\(Int(min(sample.accuracyDegrees, 360).rounded()))°")
          .font(.subheadline).foregroundStyle(.secondary)
          .accessibilityHidden(appearance.hasReadout)
          .accessibilityLabel(accessibilitySummary)
        if steadyReading {
          Text("Dial hidden while Reduce Motion is on")
            .font(.caption2).foregroundStyle(.secondary)
        }
      } else {
        Text(compass.status.title).font(.headline)
        if details {
          Text(compass.status.detail).foregroundStyle(.secondary)
        }
        if compass.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
          Link("Open Settings", destination: url).frame(minHeight: 44)
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
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }

  private func essentialReading(height: CGFloat) -> some View {
    VStack(spacing: 8) {
      if compass.sample != nil {
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
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { showingSettings = true }
  }

  private func closeSettings() {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { showingSettings = false }
    menuFocused = true
  }

  private func replayTour() {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
      showingSettings = false
      onboarding.replay()
    }
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
