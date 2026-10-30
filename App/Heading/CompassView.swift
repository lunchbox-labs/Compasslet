import CompassCore
import SwiftUI
import UIKit

struct CompassView: View {
  @ObservedObject var drive: DriveSessionController
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var compass = HeadingController(sensor: DeviceHeadingSensor())
  @ObservedObject private var appearanceStore = AppearanceStore.shared
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .title2) private var dialSize = 260

  private var appearance: AppearanceValues { appearanceStore.preferences.effective(for: .phone) }
  private var externalReadout: Bool {
    appearance.rotation == .arrow
      || appearance.readoutTextSize(system: dynamicTypeSize).isAccessibilitySize
  }
  @State private var showingSettings = false

  private var roundedDegrees: Int? {
    compass.sample.map { Int($0.angle.degrees.rounded()) % 360 }
  }

  private var accessibilitySummary: String {
    guard let sample = compass.sample, let roundedDegrees else { return compass.status.title }
    let names = [
      "north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest",
    ]
    let direction = names[Int((sample.angle.degrees + 22.5) / 45) % 8]
    let accuracy = Int(min(sample.accuracy, 360).rounded())
    return
      "\(roundedDegrees) degrees, \(direction), magnetic heading. Accuracy plus or minus \(accuracy) degrees."
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        Button {
          showingSettings = true
        } label: {
          Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
        Spacer(minLength: 8)
        VStack(spacing: 8) {
          Text("COMPASS").font(.caption.weight(.semibold)).tracking(4)
            .foregroundStyle(.secondary)
          Text("Find your bearing").font(.title2.weight(.semibold))
        }
        .multilineTextAlignment(.center)
        Spacer(minLength: 8)
        Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      if drive.isDriving {
        Button("End Drive", role: .destructive) { Task { await drive.endDrive() } }
          .padding(.top, 12)
      }
      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: 28) {
            if let notice = locationNotice {
              Button {
                showingSettings = true
              } label: {
                Label(notice, systemImage: "location.slash")
                  .font(.subheadline)
              }
            }
            dial
            if externalReadout, appearance.hasReadout, let sample = compass.sample {
              CompassReadout(bearing: sample.angle.degrees, appearance: appearance)
                .accessibilityHidden(true)
            }
            if let sample = compass.sample {
              Text("Accuracy ±\(Int(min(sample.accuracy, 360).rounded()))°")
                .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
              Label(
                compass.status.title,
                systemImage: compass.sample == nil ? "info.circle" : "location.north"
              )
              .font(.headline)
              Text(compass.status.detail).foregroundStyle(.secondary)
              if compass.status == .denied,
                let url = URL(string: UIApplication.openSettingsURLString)
              {
                Link("Open Settings", destination: url).buttonStyle(.bordered)
              }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 24))
            Text("PHONE HEADING · MAGNETIC NORTH")
              .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            Text(
              "Direction follows your phone, including when you are standing still. Nearby magnets and metal can affect accuracy."
            )
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }
          .padding(24)
          .frame(maxWidth: 520)
          .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
      }
    }
    .background(Color(uiColor: .systemBackground))
    .sheet(isPresented: $showingSettings) {
      CompassSettingsView(drive: drive)
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else {
        compass.stop()
        return
      }
      await drive.phoneBecameActive()
      guard !Task.isCancelled else { return }
      compass.setReducedMotion(reduceMotion)
      await compass.run()
    }
    .onChange(of: reduceMotion) { _, value in compass.setReducedMotion(value) }
  }

  private var locationNotice: String? {
    switch drive.setupStatus {
    case .ready: nil
    case .permissionRequired, .denied: "Enable location for CarPlay"
    case .restricted: "Location access is restricted"
    case .servicesDisabled: "Location Services is off"
    case .preciseLocationRequired: "Enable Precise Location for CarPlay"
    case .unavailable: "CarPlay travel direction unavailable"
    }
  }

  private var dial: some View {
    CompassDial(
      bearing: compass.sample?.angle.degrees, appearance: appearance,
      showsReadout: !externalReadout
    )
    .frame(maxWidth: dialSize)
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }
}
