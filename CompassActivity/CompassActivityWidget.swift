import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CompassWidgets: WidgetBundle {
  var body: some Widget {
    CompassActivityWidget()
    CompassRefreshProbeWidget()
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
    guard !context.isStale, context.state.status == .usable,
      let degrees = context.state.bearing
    else { return "—" }
    let cardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    let cardinal = cardinals[Int((degrees + 22.5) / 45) % 8]
    return "\(cardinal) \(Int(degrees.rounded()) % 360)°"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: family == .small ? 2 : 6) {
      Text("Travel · True north").font(.caption)
      Text(Self.bearing(context)).font(family == .small ? .title2 : .largeTitle).bold()
      if context.isStale {
        Text("Travel unavailable").font(.caption)
      } else if context.state.status == .usable, let time = context.state.sampleTime {
        Text(time, style: .time).font(.caption)
      } else {
        Text(status).font(.caption)
      }
    }
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
