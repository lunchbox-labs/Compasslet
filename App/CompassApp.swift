import SwiftUI
import UIKit

@main
struct CompassApp: App {
  var body: some Scene {
    WindowGroup { CompassView() }
  }
}

struct CompassView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var compass = HeadingController(sensor: DeviceHeadingSensor())

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
    ScrollView {
      VStack(spacing: 28) {
        VStack(spacing: 8) {
          Text("COMPASS").font(.caption.weight(.semibold)).tracking(4)
            .foregroundStyle(.secondary)
          Text("Find your bearing").font(.title2.weight(.semibold))
        }
        dial
        VStack(spacing: 8) {
          Text(roundedDegrees.map { "\($0)° \(direction)" } ?? "—")
            .font(.system(.largeTitle, design: .rounded, weight: .medium))
            .monospacedDigit()
            .contentTransition(.identity)
          if let sample = compass.sample {
            Text("Accuracy ±\(Int(min(sample.accuracy, 360).rounded()))°")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        VStack(spacing: 10) {
          Label(
            compass.status.title,
            systemImage: compass.sample == nil ? "info.circle" : "location.north"
          )
          .font(.headline)
          Text(compass.status.detail).foregroundStyle(.secondary)
          if compass.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
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
      .frame(maxWidth: .infinity)
    }
    .background(Color(uiColor: .systemBackground))
    .task(id: scenePhase) {
      guard scenePhase == .active else {
        compass.stop()
        return
      }
      compass.setReducedMotion(reduceMotion)
      await compass.run()
    }
    .onChange(of: reduceMotion) { _, value in compass.setReducedMotion(value) }
  }

  private var dial: some View {
    ZStack {
      Circle().stroke(.quaternary, lineWidth: 2)
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
      if let sample = compass.sample {
        Image(systemName: "location.north.fill")
          .font(.system(size: 100, weight: .ultraLight))
          .foregroundStyle(.tint)
          .rotationEffect(.degrees(sample.angle.degrees))
      } else {
        Image(systemName: "safari")
          .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.tertiary)
      }
      Circle().fill(.primary).frame(width: 8, height: 8)
    }
    .frame(width: 260, height: 260)
    .accessibilityHidden(true)
  }
}
