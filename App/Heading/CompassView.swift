import SwiftUI
import UIKit

struct CompassView: View {
  @ObservedObject var drive: DriveSessionController
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var compass = HeadingController(sensor: DeviceHeadingSensor())
  @AppStorage("rotatesCompassDial") private var rotatesDial = true
  @State private var showingSettings = false

  private var roundedDegrees: Int? {
    compass.sample.map { Int($0.angle.degrees.rounded()) % 360 }
  }

  private var direction: String {
    guard let degrees = compass.sample?.angle.degrees else { return "—" }
    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return names[Int((degrees + 22.5) / 45) % 8]
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
        Button("Settings", systemImage: "line.3.horizontal") { showingSettings = true }
          .labelStyle(.iconOnly)
          .frame(width: 44, height: 44)
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
            if !rotatesDial { headingReadout.accessibilityHidden(true) }
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
      CompassSettingsView(drive: drive, rotatesDial: $rotatesDial)
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

  private var headingReadout: some View {
    Text(roundedDegrees.map { "\($0)° \(direction)" } ?? "—")
      .font(.system(.largeTitle, design: .rounded, weight: .medium))
      .monospacedDigit()
      .contentTransition(.identity)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
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
    ZStack {
      Circle().stroke(.quaternary, lineWidth: 2)
      ZStack {
        ForEach(0..<72) { index in
          Capsule()
            .fill(index % 9 == 0 ? Color.primary : Color.secondary.opacity(0.45))
            .frame(width: index % 9 == 0 ? 2 : 1, height: index % 9 == 0 ? 16 : 7)
            .offset(y: -118)
            .rotationEffect(.degrees(Double(index) * 5))
        }
        ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, label in
          Text(label).font(.headline)
            .foregroundStyle(index == 0 ? Color.red : Color.secondary)
            .offset(
              x: index == 1 ? 90 : index == 3 ? -90 : 0,
              y: index == 0 ? -90 : index == 2 ? 90 : 0)
        }
      }
      // Samples are already circularly smoothed. No implicit interpolation means
      // crossing north cannot animate a full revolution in either display style.
      .rotationEffect(.degrees(rotatesDial ? -(compass.sample?.angle.degrees ?? 0) : 0))
      .opacity(compass.sample == nil ? 0.35 : 1)
      if let sample = compass.sample {
        if rotatesDial {
          Image(systemName: "triangle.fill")
            .font(.caption)
            .foregroundStyle(.tint)
            .rotationEffect(.degrees(180))
            .offset(y: -132)
          headingReadout.frame(maxWidth: 150)
        } else {
          Image(systemName: "location.north.fill")
            .font(.system(size: 100, weight: .ultraLight))
            .foregroundStyle(.tint)
            .rotationEffect(.degrees(sample.angle.degrees))
          Circle().fill(.primary).frame(width: 8, height: 8)
        }
      } else {
        Image(systemName: "safari")
          .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.tertiary)
      }
    }
    .frame(width: 260, height: 260)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }
}
