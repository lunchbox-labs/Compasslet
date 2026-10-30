import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CompassWidgets: WidgetBundle {
  var body: some Widget {
    CompassActivityWidget()
    CompassCourseWidget()
  }
}

struct CompassActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CompassActivityAttributes.self) { context in
      CompassActivityView(context: context)
        .padding()
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.center) { CompassActivityView(context: context) }
      } compactLeading: {
        Image(systemName: "location.north")
      } compactTrailing: {
        Text(CompassActivityView.bearing(context))
      } minimal: {
        Text(CompassActivityView.bearing(context))
      }
    }
    .supplementalActivityFamilies([.small])
  }
}

private struct CompassActivityView: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  @Environment(\.activityFamily) private var family

  static func bearing(_ context: ActivityViewContext<CompassActivityAttributes>) -> String {
    guard let reading = reading(context) else { return "—" }
    return "\(reading.cardinal) \(reading.degrees)"
  }

  private static func reading(_ context: ActivityViewContext<CompassActivityAttributes>)
    -> (cardinal: String, degrees: String)?
  {
    guard !context.isStale, context.state.status == .usable,
      let degrees = context.state.bearing, degrees.isFinite, (0..<360).contains(degrees)
    else { return nil }
    let cardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    let cardinal = cardinals[Int((degrees + 22.5) / 45) % 8]
    return (cardinal, "\(Int(degrees.rounded()) % 360)°")
  }

  var body: some View {
    VStack(spacing: family == .small ? 2 : 6) {
      if let reading = Self.reading(context) {
        Text(reading.cardinal).font(.largeTitle.bold())
        Text(reading.degrees).font(.title2).monospacedDigit()
      } else {
        Text("—").font(.largeTitle.bold())
      }
      Text("Travel · True north").font(.caption2)
      if context.isStale {
        Text("Travel unavailable").font(.caption)
      } else if context.state.status != .usable {
        Text(status).font(.caption)
      }
      if let update = context.state.debugUpdateTime {
        VStack(spacing: 1) {
          Text("Update \(update, format: .dateTime.hour().minute().second())")
          if let sample = context.state.sampleTime {
            Text("Sample \(sample, format: .dateTime.hour().minute().second())")
          }
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }

  private var status: String {
    switch context.state.status {
    case .waiting: "Waiting for travel"
    case .usable, .unavailable: "Travel unavailable"
    case .slow: "Move steadily to show travel"
    case .unreliable: "Travel direction uncertain"
    }
  }
}
