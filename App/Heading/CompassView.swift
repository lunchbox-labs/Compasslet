import CompassCore
import SwiftUI
import UIKit

struct CompassView: View {
  @ObservedObject var drive: DriveSessionController
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @StateObject private var compass = HeadingController(sensor: DeviceHeadingSensor())
  @StateObject private var location = PhoneLocationController()
  @ObservedObject private var appearanceStore = AppearanceStore.shared
  @State private var showingSettings = false
  @State private var showingLocationDetails = false
  @State private var debugEnabled = false
  @AccessibilityFocusState private var menuFocused: Bool

  private var appearance: AppearanceValues { appearanceStore.preferences.effective(for: .phone) }
  private var roundedDegrees: Int? {
    compass.sample.map { Int($0.angle.degrees.rounded()) % 360 }
  }
  private var accessibilitySummary: String {
    guard let sample = compass.sample, let roundedDegrees else { return compass.status.title }
    let names = [
      "north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest",
    ]
    let direction = names[Int((sample.angle.degrees + 22.5) / 45) % 8]
    return
      "\(roundedDegrees) degrees, \(direction), magnetic heading. Accuracy plus or minus \(Int(min(sample.accuracy, 360).rounded())) degrees."
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        VStack(spacing: 0) {
          header
          GeometryReader { content in
            ViewThatFits(in: .vertical) {
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
              // All supporting details remain available in the scrollable drawer.
              essentialReading
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .allowsHitTesting(!showingSettings)
        .accessibilityHidden(showingSettings)
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
          Color.black.opacity(0.55)
            .ignoresSafeArea()
            .onTapGesture { closeSettings() }
            .accessibilityHidden(true)
          CompassSettingsView(
            drive: drive, location: location, headingStatus: compass.status,
            showLocationDetails: showingLocationDetails, close: closeSettings
          )
          .frame(width: min(420, max(0, geometry.size.width - 44)))
          .overlay(alignment: .trailing) {
            Capsule().fill(.secondary).frame(width: 4, height: 52)
              .frame(width: 44, height: 100)
              .contentShape(Rectangle())
              .gesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                  if value.translation.width < -40,
                    abs(value.translation.height) < -value.translation.width / 2
                  {
                    closeSettings()
                  }
                }
              )
              .accessibilityHidden(true)
          }
          .accessibilityAddTraits(.isModal)
          .accessibilityAction(.escape, closeSettings)
          .transition(reduceMotion ? .opacity : .move(edge: .leading))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .background(Color(uiColor: .systemBackground))
    .task(id: scenePhase) {
      guard scenePhase == .active else {
        compass.stop()
        location.stop()
        return
      }
      await drive.phoneBecameActive()
      guard !Task.isCancelled else { return }
      compass.setReducedMotion(reduceMotion)
      async let heading: Void = compass.run()
      async let phoneLocation: Void = location.run()
      while !Task.isCancelled {
        debugEnabled = (try? CompassDiagnostics.shared?.isEnabled()) ?? false
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
      _ = await heading
      _ = await phoneLocation
    }
    .onChange(of: reduceMotion) { _, value in compass.setReducedMotion(value) }
  }

  private var header: some View {
    HStack {
      Button(action: { openSettings() }) {
        Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Settings")
      .accessibilityFocused($menuFocused)
      Spacer(minLength: 8)
      Text("Compasslet").font(.headline)
      Spacer(minLength: 8)
      if drive.isDriving {
        Button("End Drive", role: .destructive) { Task { await drive.endDrive() } }
          .frame(minWidth: 44, minHeight: 44)
      } else {
        Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
  }

  private func information(details: Bool) -> some View {
    VStack(spacing: details ? 16 : 8) {
      if let sample = compass.sample {
        phoneReadout
        Text("Accuracy ±\(Int(min(sample.accuracy, 360).rounded()))°")
          .font(.subheadline).foregroundStyle(.secondary)
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
      } else {
        Button("Location details", systemImage: "chevron.right") {
          openSettings(locationDetails: true)
        }
        .frame(minHeight: 44)
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

  @ViewBuilder private var essentialReading: some View {
    if compass.sample != nil {
      phoneReadout
    } else {
      Button(action: { openSettings(locationDetails: true) }) {
        Text(compass.status.title).font(.headline).multilineTextAlignment(.center)
      }
      .frame(minHeight: 44)
      .accessibilityHint("Opens details and available recovery actions")
    }
  }

  private var phoneReadout: some View {
    PhoneCompassReadout(bearing: compass.sample?.angle.degrees ?? 0, appearance: appearance)
      .dynamicTypeSize(appearance.readoutTextSize(system: dynamicTypeSize))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilitySummary)
  }

  private func dial(size: CGFloat) -> some View {
    CompassDial(bearing: compass.sample?.angle.degrees, appearance: appearance, showsReadout: false)
      .frame(width: max(0, size), height: max(0, size))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilitySummary)
  }

  private var locationNotice: String? {
    switch drive.setupStatus {
    case .ready: nil
    case .permissionRequired: "Enable location"
    case .denied: "Location access denied"
    case .restricted: "Location access is restricted"
    case .servicesDisabled: "Location Services is off"
    case .preciseLocationRequired: "Approximate location · Enable Precise Location"
    case .unavailable: "CarPlay travel direction unavailable"
    }
  }

  private func openSettings(locationDetails: Bool = false) {
    showingLocationDetails = locationDetails
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { showingSettings = true }
  }

  private func closeSettings() {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { showingSettings = false }
    menuFocused = true
  }
}

struct PhoneCompassReadout: View {
  let bearing: Double
  let appearance: AppearanceValues
  @ScaledMetric(relativeTo: .largeTitle) private var textSize = 60

  var body: some View {
    VStack(spacing: 0) {
      if appearance.showDirection {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        Text(names[Int((bearing + 22.5) / 45) % 8])
      }
      if appearance.showDegrees {
        Text("\(Int(bearing.rounded()) % 360)°").monospacedDigit()
      }
    }
    .font(.system(size: textSize, weight: .light))
  }
}
