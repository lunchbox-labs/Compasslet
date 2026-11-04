import ActivityKit
import CompassCore
import SwiftUI
import WidgetKit

@main
struct CompassLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    CompassActivityWidget()
  }
}

struct CompassActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CompassActivityAttributes.self) { context in
      ActivityCard(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        // The island's regions have fixed bounds, so the readout stops at the largest
        // standard size there; the Lock Screen and small presentations use the full range.
        DynamicIslandExpandedRegion(.center) {
          CompassActivityView(
            state: context.state, isStale: context.isStale, maximumTextSize: .xxxLarge)
        }
      } compactLeading: {
        // The trailing readout speaks the whole state; the arrow is decorative.
        IslandArrow(context: context).accessibilityHidden(true)
      } compactTrailing: {
        ActivityCompactReadout(context: context)
      } minimal: {
        IslandArrow(context: context)
          .accessibilityLabel(
            CompassActivityView.accessibilitySummary(state: context.state, isStale: context.isStale)
          )
      }
    }
    .supplementalActivityFamilies([.small])
  }
}

private struct ActivityCard: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  @Environment(\.activityFamily) private var family

  var body: some View {
    CompassActivityCard(state: context.state, isStale: context.isStale, isSmall: family == .small)
  }
}

/// Turns with the direction of travel while there's a reading, and shows a plain north outline
/// while waiting or stale, so a held arrow never looks current.
private struct IslandArrow: View {
  let context: ActivityViewContext<CompassActivityAttributes>

  var body: some View {
    let presentation = CompassActivityReading(state: context.state, isStale: context.isStale)
    if let reading = presentation.reading {
      TravelArrow(degrees: reading.roundedDegrees)
    } else {
      Image(systemName: "location.north")
    }
  }
}

private struct ActivityCompactReadout: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  @Environment(\.dynamicTypeSize) private var systemTextSize

  var body: some View {
    let presentation = CompassActivityReading(state: context.state, isStale: context.isStale)
    Text(presentation.reading == nil ? "—" : "Last \(presentation.bearing)")
      .font(.caption).lineLimit(1).minimumScaleFactor(0.85)
      // The compact island has fixed bounds, so the readout stops at the largest standard size.
      .dynamicTypeSize(
        min(presentation.appearance.readoutTextSize(system: systemTextSize), .xxxLarge)
      )
      .accessibilityLabel(
        CompassActivityView.accessibilitySummary(state: context.state, isStale: context.isStale))
  }
}
