import CompassCore
import SwiftUI

/// The phone and settings previews use the same dial geometry.
struct CompassDial: View {
  let bearing: Double?
  let appearance: AppearanceValues
  var showsReadout = true

  var body: some View {
    GeometryReader { geometry in
      let available = max(0, min(geometry.size.width, geometry.size.height))
      // Outside labels reserve space inside the view instead of overflowing the tile.
      let diameter = max(0, available - (appearance.labels == .outside ? 42 : 12))
      let radius = diameter / 2
      let rotation = appearance.rotation == .dial ? -(bearing ?? 0) : 0
      ZStack {
        Circle().stroke(.quaternary, lineWidth: 1)
        ForEach(Array(appearance.minorTicks.angles.enumerated()), id: \.offset) { index, angle in
          let major = index % (appearance.minorTicks.rawValue + 1) == 0
          Capsule()
            .fill(index == 0 ? Color.red : (major ? Color.primary : Color.secondary))
            .frame(width: major ? 2 : 1, height: diameter * (major ? 0.06 : 0.025))
            .offset(y: -radius * 0.9)
            .rotationEffect(.degrees(angle + rotation))
        }
        if appearance.labels != .hidden {
          ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, label in
            let angle = (Double(index) * 90 + rotation - 90) * .pi / 180
            let distance = appearance.labels == .outside ? radius + 13 : radius * 0.7
            Text(label).font(.system(size: max(11, min(18, diameter * 0.085)), weight: .semibold))
              .foregroundStyle(index == 0 ? Color.red : Color.secondary)
              .offset(x: distance * CGFloat(cos(angle)), y: distance * CGFloat(sin(angle)))
          }
        }
        if let bearing {
          if appearance.rotation == .dial {
            Image(systemName: "triangle.fill")
              .font(.system(size: diameter * 0.075)).foregroundStyle(.tint)
              .rotationEffect(.degrees(180)).offset(y: -radius)
            if showsReadout {
              CompassReadout(
                bearing: bearing, appearance: appearance, degreesFirst: true, compact: true
              )
              .frame(width: diameter * (appearance.labels == .outside ? 0.78 : 0.56))
            }
          } else {
            Image(systemName: "location.north.fill")
              .font(.system(size: diameter * 0.4, weight: .ultraLight)).foregroundStyle(.tint)
              .rotationEffect(.degrees(bearing))
          }
        } else {
          Image(systemName: "safari").font(.largeTitle).foregroundStyle(.tertiary)
        }
      }
      .opacity(bearing == nil ? 0.35 : 1)
      .frame(width: diameter, height: diameter)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct CompassReadout: View {
  let bearing: Double
  let appearance: AppearanceValues
  var degreesFirst = false
  var compact = false
  @Environment(\.dynamicTypeSize) private var systemTextSize

  private var cardinal: String {
    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return names[Int((bearing + 22.5) / 45) % 8]
  }

  var body: some View {
    VStack(spacing: compact ? 0 : 2) {
      if degreesFirst {
        degrees
        direction
      } else {
        direction
        degrees
      }
    }
    .multilineTextAlignment(.center)
    .lineLimit(1)
    .minimumScaleFactor(0.85)
    .contentTransition(.identity)
    .dynamicTypeSize(appearance.readoutTextSize(system: systemTextSize))
  }

  @ViewBuilder private var direction: some View {
    if appearance.showDirection {
      Text(cardinal).font((compact ? Font.headline : Font.largeTitle).weight(.semibold))
    }
  }

  @ViewBuilder private var degrees: some View {
    if appearance.showDegrees {
      Text("\(Int(bearing.rounded()) % 360)°")
        .font(compact ? .title3 : .title2).monospacedDigit()
    }
  }
}

extension AppearanceValues {
  func readoutTextSize(system: DynamicTypeSize) -> DynamicTypeSize {
    useSystemTextSize ? system : customTextSize.dynamicTypeSize
  }
}

extension ReadoutTextSize {
  var dynamicTypeSize: DynamicTypeSize {
    switch self {
    case .xSmall: .xSmall
    case .small: .small
    case .medium: .medium
    case .large: .large
    case .xLarge: .xLarge
    case .xxLarge: .xxLarge
    case .xxxLarge: .xxxLarge
    case .accessibility1: .accessibility1
    case .accessibility2: .accessibility2
    case .accessibility3: .accessibility3
    case .accessibility4: .accessibility4
    case .accessibility5: .accessibility5
    }
  }

  var title: String {
    switch self {
    case .xSmall: "Extra Small"
    case .small: "Small"
    case .medium: "Medium"
    case .large: "Default"
    case .xLarge: "Extra Large"
    case .xxLarge: "Extra Extra Large"
    case .xxxLarge: "Extra Extra Extra Large"
    case .accessibility1: "Accessibility Medium"
    case .accessibility2: "Accessibility Large"
    case .accessibility3: "Accessibility Extra Large"
    case .accessibility4: "Accessibility Extra Extra Large"
    case .accessibility5: "Accessibility Extra Extra Extra Large"
    }
  }
}
