import CompassCore
import SwiftUI

struct CompassActivityCard: View {
  let state: CompassActivityAttributes.ContentState
  var isStale = false
  var isSmall = false
  @Environment(\.dynamicTypeSize) private var systemTextSize

  private var presentation: CompassActivityReading {
    CompassActivityReading(state: state, isStale: isStale)
  }

  var body: some View {
    if isSmall {
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
          if presentation.reading != nil, presentation.appearance.smallActivityTimestamp != .hidden
          {
            Text("Last Travel").font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(CompassActivityView.accessibilitySummary(state: state, isStale: isStale))
    } else {
      CompassActivityView(state: state, isStale: isStale).padding()
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
      if presentation.reading != nil, let sample = state.sampleTime {
        ActivityTimestamp(sample: sample, mode: presentation.appearance.smallActivityTimestamp)
      } else {
        Text("Travel · True North")
      }
    }
    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    .lineLimit(1).minimumScaleFactor(0.85)
  }
}

struct CompassActivityView: View {
  let state: CompassActivityAttributes.ContentState
  var isStale = false
  var maximumTextSize: DynamicTypeSize = .accessibility5

  /// One spoken description for every presentation, so a retained reading is only ever
  /// announced as recorded travel when one is actually shown.
  static func accessibilitySummary(state: CompassActivityAttributes.ContentState, isStale: Bool)
    -> Text
  {
    let presentation = CompassActivityReading(state: state, isStale: isStale)
    let summary: Text
    if presentation.reading != nil, let sample = state.sampleTime {
      summary = Text("\(presentation.spokenDescription), sampled \(sample, style: .time).")
    } else {
      summary = Text("\(presentation.spokenDescription).")
    }
    guard let update = state.debugUpdateTime else { return summary }
    let debug = Text("\(summary) Update \(update, format: .dateTime.hour().minute().second()).")
    guard let sample = state.sampleTime else { return debug }
    return Text("\(debug) Sample \(sample, format: .dateTime.hour().minute().second()).")
  }

  var body: some View {
    let presentation = CompassActivityReading(state: state, isStale: isStale)
    VStack(spacing: 6) {
      if presentation.reading != nil {
        CompassReadout(
          bearing: state.bearing ?? 0, appearance: presentation.appearance,
          maximumTextSize: maximumTextSize
        )
      } else {
        Text("—").font(.largeTitle.bold())
      }
      Text("Travel · True North").font(.caption2)
      if presentation.reading != nil, let sample = state.sampleTime {
        ActivityTimestamp(sample: sample, mode: presentation.appearance.lockScreenTimestamp)
          .font(.caption2).foregroundStyle(.secondary)
      }
      if isStale || state.status != .usable {
        Text(presentation.status).font(.caption)
      }
      if let update = state.debugUpdateTime {
        VStack(spacing: 1) {
          Text("Update \(update, format: .dateTime.hour().minute().second())")
          if let sample = state.sampleTime {
            Text("Sample \(sample, format: .dateTime.hour().minute().second())")
          }
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilitySummary(state: state, isStale: isStale))
  }
}

/// The system advances the timer without requiring new ActivityKit updates.
struct ActivityTimestamp: View {
  let sample: Date
  let mode: ActivityTimestampMode

  var body: some View {
    switch mode {
    case .hidden:
      EmptyView()
    case .time:
      Text("Last Travel \(sample, style: .time)")
    case .elapsed:
      HStack(spacing: 4) {
        Text("Last Travel")
        Text(timerInterval: sample...Date.distantFuture, countsDown: false)
          .monospacedDigit().fixedSize()
      }
    }
  }
}
