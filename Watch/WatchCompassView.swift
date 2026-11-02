import CompassCore
import SwiftUI

struct WatchCompassView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var textSize
  @State private var showsExperimentalNotice = false
  @StateObject private var compass = HeadingController(sensor: DeviceHeadingSensor())

  private var appearance: AppearanceValues {
    var value = AppearanceValues()
    value.minorTicks = .eight
    return value
  }

  private var usesSteppedHeading: Bool { reduceMotion && textSize < .xxxLarge }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 4) {
        if textSize >= .xxxLarge {
          readout
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ZStack {
            CompassDial(
              bearing: compass.sample?.angle.degrees, appearance: appearance,
              showsReadout: false, unavailableSymbol: "minus")
            readout.frame(
              width: max(0, min(geometry.size.width, geometry.size.height - 88)) * 0.50)
          }
          .aspectRatio(1, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(accessibilitySummary)
        }
        Text(compass.status.watchTitle)
          .font(.caption2)
          .foregroundStyle(compass.sample == nil ? .primary : .secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Button("Experimental") { showsExperimentalNotice = true }
          .font(.caption2)
          .accessibilityHint("Explains the limitations of Apple Watch support")
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 4)
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .sheet(isPresented: $showsExperimentalNotice) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Experimental Support").font(.headline)
          Text(
            "Apple Watch runtime and device validation are incomplete. Support is experimental and may not work as expected."
          )
          Button("Done") { showsExperimentalNotice = false }
        }
        .padding()
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else {
        compass.stop()
        return
      }
      compass.setReducedMotion(usesSteppedHeading)
      await compass.run()
    }
    .onChange(of: usesSteppedHeading) { _, value in compass.setReducedMotion(value) }
  }

  private var readout: some View {
    Group {
      if let sample = compass.sample {
        CompassReadout(
          bearing: sample.angle.degrees, appearance: appearance, degreesFirst: true, compact: true)
      } else {
        Text("—").font(.largeTitle)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  private var accessibilitySummary: String {
    guard let sample = compass.sample else { return compass.status.watchTitle }
    let names = [
      "north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest",
    ]
    let direction = names[Int((sample.angle.degrees + 22.5) / 45) % 8]
    return
      "\(Int(sample.angle.degrees.rounded()) % 360) degrees, \(direction), magnetic heading. Accuracy plus or minus \(Int(min(sample.accuracy, 360).rounded())) degrees."
  }
}

extension HeadingController.Status {
  var watchTitle: String {
    switch self {
    case .inactive: "Compass paused"
    case .waiting: "Finding north…"
    case .live: "Magnetic heading"
    case .stale: "Waiting for a fresh heading"
    case .calibration: "Move away from magnets and metal"
    case .unavailable: "Heading unavailable"
    case .denied: "Heading access unavailable"
    case .interrupted: "Heading interrupted"
    }
  }
}
