import CompassCore
import SwiftUI

struct WatchCompassView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var textSize
  @StateObject private var compass = HeadingController(sensor: DeviceHeadingSensor())

  private var appearance: AppearanceValues {
    var value = AppearanceValues()
    value.minorTicks = .eight
    return value
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 4) {
        if textSize.isAccessibilitySize {
          readout
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ZStack {
            CompassDial(
              bearing: compass.sample?.angle.degrees, appearance: appearance,
              showsReadout: false, unavailableSymbol: "minus")
            if compass.sample != nil {
              readout.frame(width: min(geometry.size.width, geometry.size.height - 44) * 0.50)
            }
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
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 4)
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
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

  private var readout: some View {
    Group {
      if let sample = compass.sample {
        CompassReadout(bearing: sample.angle.degrees, appearance: appearance, degreesFirst: true)
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
