import CompassCore
import SwiftUI

/// The phone and settings previews use the same dial geometry.
///
/// North is marked by shape as well as color: its rim tick is a pointed marker, longer and
/// wider than the other major ticks, so it stays identifiable with cardinal labels hidden, in
/// grayscale and with Differentiate Without Color on. Increase Contrast darkens the labels and
/// rim and thickens the minor ticks without promoting decorative marks to the primary color.
struct CompassDial: View {
  let bearing: Double?
  let appearance: AppearanceValues
  var showsReadout = true
  @Environment(\.colorSchemeContrast) private var contrast

  private var increasedContrast: Bool { contrast == .increased }
  private var labelColor: Color { increasedContrast ? .primary : .secondary }

  var body: some View {
    GeometryReader { geometry in
      let available = max(0, min(geometry.size.width, geometry.size.height))
      // Outside labels reserve space inside the view instead of overflowing the tile.
      let diameter = max(0, available - (appearance.labels == .outside ? 42 : 12))
      let radius = diameter / 2
      let rotation = appearance.rotation == .dial ? -(bearing ?? 0) : 0
      let rim: HierarchicalShapeStyle = increasedContrast ? .tertiary : .quaternary
      ZStack {
        Circle().stroke(rim, lineWidth: increasedContrast ? 1.5 : 1)
        ForEach(Array(appearance.minorTicks.angles.enumerated()), id: \.offset) { index, angle in
          let major = index % (appearance.minorTicks.rawValue + 1) == 0
          Group {
            if index == 0 {
              // Spans 0.80r to 0.96r: longer than a major tick, clear of the inside labels,
              // and ending before the fixed index triangle so the two never merge near north.
              NorthMarker()
                .fill(Color.red)
                .frame(width: diameter * 0.06, height: diameter * 0.08)
                .offset(y: radius * 0.02)
            } else {
              Capsule()
                .fill(major ? Color.primary : Color.secondary)
                .frame(
                  width: major ? 2 : (increasedContrast ? 1.5 : 1),
                  height: diameter * (major ? 0.06 : 0.025))
            }
          }
          .offset(y: -radius * 0.9)
          .rotationEffect(.degrees(angle + rotation))
        }
        if appearance.labels != .hidden {
          ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, label in
            let angle = (Double(index) * 90 + rotation - 90) * .pi / 180
            let distance = appearance.labels == .outside ? radius + 13 : radius * 0.7
            Text(label).font(.system(size: max(11, min(18, diameter * 0.085)), weight: .semibold))
              .foregroundStyle(index == 0 ? Color.red : labelColor)
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
              .font(
                .system(size: diameter * 0.4, weight: increasedContrast ? .regular : .ultraLight)
              )
              .foregroundStyle(.tint)
              .rotationEffect(.degrees(bearing))
          }
        } else {
          Image(systemName: "safari").font(.largeTitle).foregroundStyle(.tertiary)
        }
      }
      // Without a reading the dial is dimmed; status text carries the explanation.
      .opacity(bearing == nil ? (increasedContrast ? 0.6 : 0.35) : 1)
      .frame(width: diameter, height: diameter)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// A rim marker pointing outward: wider at the base than any tick and pointed at the rim.
private struct NorthMarker: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

struct CompassReadout: View {
  let bearing: Double
  let appearance: AppearanceValues
  var degreesFirst = false
  var compact = false
  /// Presentations with fixed bounds, such as the Dynamic Island, pass a lower limit.
  var maximumTextSize: DynamicTypeSize = .accessibility5
  @Environment(\.dynamicTypeSize) private var systemTextSize

  private var cardinal: String { CompassPoint(degrees: bearing)?.abbreviation ?? "—" }

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
    .dynamicTypeSize(min(appearance.readoutTextSize(system: systemTextSize), maximumTextSize))
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
