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
      CompassActivityCard(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        // The island's regions have fixed bounds, so the readout stops at the largest
        // standard size there; the Lock Screen and small presentations use the full range.
        DynamicIslandExpandedRegion(.center) {
          CompassActivityView(context: context, maximumTextSize: .xxxLarge)
        }
      } compactLeading: {
        // The trailing readout speaks the whole state; the icon is decorative.
        Image(systemName: "location.north").accessibilityHidden(true)
      } compactTrailing: {
        ActivityCompactReadout(context: context)
      } minimal: {
        Image(systemName: "location.north")
          .accessibilityLabel(CompassActivityView.accessibilitySummary(context))
      }
    }
    .supplementalActivityFamilies([.small])
  }
}

private struct CompassActivityCard: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  @Environment(\.activityFamily) private var family
  @Environment(\.dynamicTypeSize) private var systemTextSize

  private var presentation: CompassActivityReading { CompassActivityView.presentation(context) }

  var body: some View {
    if family == .small {
      ViewThatFits(in: .vertical) {
        VStack(spacing: 2) {
          // Reserve equal space above and below so diagnostics never move the reading.
          secondaryLine.hidden().accessibilityHidden(true)
          readout
          secondaryLine
        }
        .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 1) {
          readout
          if presentation.reading != nil {
            Text("Last Travel").font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(CompassActivityView.accessibilitySummary(context))
    } else {
      CompassActivityView(context: context).padding()
    }
  }

  /// At large text sizes the reading drops to a shorter form (degrees, then direction) before
  /// any text is scaled down, so an enlarged size stays enlarged; the accessibility label keeps
  /// every detail. Status text keeps its single shrinking line.
  private var readout: some View {
    Group {
      if presentation.reading == nil {
        readoutText(presentation.status).lineLimit(1).minimumScaleFactor(0.5)
      } else {
        ViewThatFits(in: .horizontal) {
          ForEach(presentation.bearingCandidates, id: \.self) { candidate in
            readoutText(candidate).lineLimit(1).minimumScaleFactor(0.8)
          }
        }
      }
    }
    .dynamicTypeSize(presentation.appearance.readoutTextSize(system: systemTextSize))
    .frame(maxWidth: .infinity)
    .contentTransition(.identity)
  }

  private func readoutText(_ text: String) -> some View {
    Text(text)
      .font(.title2.weight(.semibold)).monospacedDigit()
      .multilineTextAlignment(.center)
  }

  private var secondaryLine: some View {
    Group {
      if presentation.reading != nil, let sample = context.state.sampleTime {
        Text("Last Travel \(sample, style: .time)")
      } else {
        Text("Travel · True North")
      }
    }
    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    .lineLimit(1).minimumScaleFactor(0.85)
  }
}

private struct CompassActivityView: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  var maximumTextSize: DynamicTypeSize = .accessibility5
  @Environment(\.activityFamily) private var family

  static func presentation(_ context: ActivityViewContext<CompassActivityAttributes>)
    -> CompassActivityReading
  {
    CompassActivityReading(state: context.state, isStale: context.isStale)
  }

  /// One spoken description for every presentation, so a retained reading is only ever
  /// announced as recorded travel when one is actually shown.
  static func accessibilitySummary(_ context: ActivityViewContext<CompassActivityAttributes>)
    -> Text
  {
    let presentation = presentation(context)
    let summary: Text
    if presentation.reading != nil, let sample = context.state.sampleTime {
      summary = Text("\(presentation.spokenDescription), sampled \(sample, style: .time).")
    } else {
      summary = Text("\(presentation.spokenDescription).")
    }
    guard let update = context.state.debugUpdateTime else { return summary }
    let debug = Text("\(summary) Update \(update, format: .dateTime.hour().minute().second()).")
    guard let sample = context.state.sampleTime else { return debug }
    return Text("\(debug) Sample \(sample, format: .dateTime.hour().minute().second()).")
  }

  var body: some View {
    let presentation = Self.presentation(context)
    VStack(spacing: family == .small ? 2 : 6) {
      if presentation.reading != nil {
        CompassReadout(
          bearing: context.state.bearing ?? 0, appearance: presentation.appearance,
          maximumTextSize: maximumTextSize
        )
      } else {
        Text("—").font(.largeTitle.bold())
      }
      Text("Travel · True North").font(.caption2)
      if presentation.reading != nil, let sample = context.state.sampleTime {
        Text("Last Travel \(sample, style: .time)").font(.caption2).foregroundStyle(.secondary)
      }
      if context.isStale || context.state.status != .usable {
        Text(presentation.status).font(.caption)
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilitySummary(context))
  }
}

private struct ActivityCompactReadout: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  @Environment(\.dynamicTypeSize) private var systemTextSize

  var body: some View {
    let presentation = CompassActivityView.presentation(context)
    Text(presentation.reading == nil ? "—" : "Last \(presentation.bearing)")
      .font(.caption).lineLimit(1).minimumScaleFactor(0.85)
      // The compact island has fixed bounds, so the readout stops at the largest standard size.
      .dynamicTypeSize(
        min(presentation.appearance.readoutTextSize(system: systemTextSize), .xxxLarge)
      )
      .accessibilityLabel(CompassActivityView.accessibilitySummary(context))
  }
}
