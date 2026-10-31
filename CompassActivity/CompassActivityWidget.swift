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
        Image(systemName: "location.north")
      } compactTrailing: {
        ActivityCompactReadout(context: context)
      } minimal: {
        Image(systemName: "location.north")
          .accessibilityLabel("Last recorded travel direction. Expand for reading.")
      }
    }
    .supplementalActivityFamilies([.small])
  }
}

private struct CompassActivityCard: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  @Environment(\.activityFamily) private var family
  @Environment(\.dynamicTypeSize) private var systemTextSize

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
          if CompassActivityView.reading(context) != nil {
            Text("Last travel").font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilitySummary)
    } else {
      CompassActivityView(context: context).padding()
    }
  }

  /// At large text sizes the reading drops to a shorter form (degrees, then direction) before
  /// any text is scaled down, so an enlarged size stays enlarged; the accessibility label keeps
  /// every detail. Status text keeps its single shrinking line.
  private var readout: some View {
    Group {
      if CompassActivityView.reading(context) == nil {
        readoutText(status).lineLimit(1).minimumScaleFactor(0.5)
      } else {
        ViewThatFits(in: .horizontal) {
          ForEach(CompassActivityView.bearingCandidates(context), id: \.self) { candidate in
            readoutText(candidate).lineLimit(1).minimumScaleFactor(0.8)
          }
        }
      }
    }
    .dynamicTypeSize(
      (context.state.appearance ?? AppearanceValues()).readoutTextSize(system: systemTextSize)
    )
    .frame(maxWidth: .infinity)
    .contentTransition(.identity)
  }

  private func readoutText(_ text: String) -> some View {
    Text(text)
      .font(.title2.weight(.semibold)).monospacedDigit()
      .multilineTextAlignment(.center)
  }

  private var status: String {
    context.isStale ? "Travel unavailable" : CompassActivityView.status(context)
  }

  private var secondaryLine: some View {
    Group {
      if CompassActivityView.reading(context) != nil, let sample = context.state.sampleTime {
        Text("Last travel \(sample, style: .time)")
      } else {
        Text("Travel · True north")
      }
    }
    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    .lineLimit(1).minimumScaleFactor(0.85)
  }

  private var accessibilitySummary: Text {
    let reading =
      CompassActivityView.reading(context) == nil
      ? Text(status) : Text(CompassActivityView.bearing(context))
    let summary: Text
    if let sample = context.state.sampleTime, CompassActivityView.reading(context) != nil {
      summary = Text(
        "\(reading), last recorded travel direction, true north, sampled \(sample, style: .time).")
    } else {
      summary = Text("\(reading), travel direction, true north.")
    }
    guard let update = context.state.debugUpdateTime else { return summary }
    let debug = Text("\(summary) Update \(update, format: .dateTime.hour().minute().second()).")
    guard let sample = context.state.sampleTime else { return debug }
    return Text("\(debug) Sample \(sample, format: .dateTime.hour().minute().second()).")
  }
}

private struct CompassActivityView: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  var maximumTextSize: DynamicTypeSize = .accessibility5
  @Environment(\.activityFamily) private var family

  static func bearing(_ context: ActivityViewContext<CompassActivityAttributes>) -> String {
    guard let reading = reading(context) else { return "—" }
    let appearance = (context.state.appearance ?? AppearanceValues()).requiringReadout()
    return [
      appearance.showDirection ? reading.cardinal : nil,
      appearance.showDegrees ? reading.degrees : nil,
    ].compactMap { $0 }.joined(separator: " ")
  }

  /// The full reading followed by its shorter forms, degrees then direction, when both fields
  /// are shown; a single-field reading has nothing shorter.
  static func bearingCandidates(_ context: ActivityViewContext<CompassActivityAttributes>)
    -> [String]
  {
    guard let reading = reading(context) else { return [] }
    let appearance = (context.state.appearance ?? AppearanceValues()).requiringReadout()
    guard appearance.showDirection && appearance.showDegrees else { return [bearing(context)] }
    return [bearing(context), reading.degrees, reading.cardinal]
  }

  static func reading(_ context: ActivityViewContext<CompassActivityAttributes>)
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
      if Self.reading(context) != nil {
        CompassReadout(
          bearing: context.state.bearing ?? 0,
          appearance: (context.state.appearance ?? AppearanceValues()).requiringReadout(),
          maximumTextSize: maximumTextSize
        )
      } else {
        Text("—").font(.largeTitle.bold())
      }
      Text("Travel · True north").font(.caption2)
      if Self.reading(context) != nil, let sample = context.state.sampleTime {
        Text("Last travel \(sample, style: .time)").font(.caption2).foregroundStyle(.secondary)
      }
      if context.isStale {
        Text("Travel unavailable").font(.caption)
      } else if context.state.status != .usable {
        Text(Self.status(context)).font(.caption)
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

  static func status(_ context: ActivityViewContext<CompassActivityAttributes>) -> String {
    switch context.state.status {
    case .waiting: "Waiting for travel"
    case .usable, .unavailable: "Travel unavailable"
    case .slow: "Move steadily to show travel"
    case .unreliable: "Travel direction uncertain"
    }
  }
}

private struct ActivityCompactReadout: View {
  let context: ActivityViewContext<CompassActivityAttributes>
  @Environment(\.dynamicTypeSize) private var systemTextSize

  var body: some View {
    Text(
      CompassActivityView.reading(context) == nil
        ? "—" : "Last \(CompassActivityView.bearing(context))"
    )
    .font(.caption).lineLimit(1).minimumScaleFactor(0.85)
    // The compact island has fixed bounds, so the readout stops at the largest standard size.
    .dynamicTypeSize(
      min(
        (context.state.appearance ?? AppearanceValues()).readoutTextSize(system: systemTextSize),
        .xxxLarge)
    )
    .accessibilityLabel(
      Text("\(CompassActivityView.bearing(context)), last recorded travel direction, true north.")
    )
  }
}
