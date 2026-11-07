import CompassCore
import SwiftUI

/// The Live Activity on the Lock Screen and in CarPlay: the reading on one line, with Last Updated
/// beneath it. The Lock Screen card uses a larger readout and stays within the 84 to 160 point
/// height Apple allows; the small card fills the size CarPlay gives it.
struct CompassActivityCard: View {
  let state: CompassActivityAttributes.ContentState
  var isStale = false
  var isSmall = false
  @Environment(\.dynamicTypeSize) private var systemTextSize

  private var presentation: CompassActivityReading {
    CompassActivityReading(state: state, isStale: isStale)
  }

  private var timestampMode: ActivityTimestampMode {
    isSmall
      ? presentation.appearance.carPlayActivityTimestamp
      : presentation.appearance.lockScreenTimestamp
  }

  var body: some View {
    Group {
      if isSmall {
        layouts
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        LockScreenHeight {
          layouts
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(CompassActivityView.accessibilitySummary(state: state, isStale: isStale))
  }

  /// The tallest layout that fits: diagnostics (Lock Screen only), then the reading between
  /// balanced lines, then (Lock Screen only) the reading above its Last Updated line, then a bare
  /// Last Updated, then the reading alone, so the Lock Screen card never grows past 160 points
  /// and the CarPlay card never outgrows the size CarPlay gives it. In CarPlay, a status long
  /// enough to wrap leaves no room for the line beneath it.
  private var layouts: some View {
    ViewThatFits(in: .vertical) {
      if !isSmall, let update = state.debugUpdateTime {
        VStack(spacing: 2) {
          balanced
          diagnostics(update: update)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      balanced.fixedSize(horizontal: false, vertical: true)
      if !isSmall {
        VStack(spacing: 2) {
          readout
          secondaryLine
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 2) {
        readout
        if presentation.reading != nil, timestampMode != .hidden {
          Text("Last Updated").font(.caption2).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(Self.captionScale)
        }
      }
      readout.fixedSize(horizontal: false, vertical: true)
    }
  }

  private var balanced: some View {
    VStack(spacing: 2) {
      // An equal line above centers the reading against the line below.
      secondaryLine.hidden().accessibilityHidden(true)
      readout
      secondaryLine
    }
  }

  private func diagnostics(update: Date) -> some View {
    VStack(spacing: 2) {
      Text("Update \(update, format: .dateTime.hour().minute().second())")
      if let sample = state.sampleTime {
        Text("Sample \(sample, format: .dateTime.hour().minute().second())")
      }
    }
    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    .lineLimit(1).minimumScaleFactor(0.85)
  }

  /// At large text sizes the reading drops to a shorter form (degrees, then direction) before
  /// any text is scaled down, so an enlarged size stays enlarged; the accessibility label keeps
  /// every detail. Status text wraps to a second line before it shrinks: in CarPlay to no less
  /// than half size, so two lines still fit its card at the largest text sizes, and on the Lock
  /// Screen, where it also uses a smaller style, to no less than 80%.
  private var readout: some View {
    Group {
      if presentation.reading == nil {
        if isSmall {
          readoutText(presentation.status).lineLimit(2).minimumScaleFactor(0.5)
        } else {
          Text(presentation.status)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2).minimumScaleFactor(0.8)
        }
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
      .font((isSmall ? Font.title2 : Font.largeTitle).weight(.semibold)).monospacedDigit()
      .multilineTextAlignment(.center)
  }

  /// How far the Last Updated line may shrink. At the largest text size with Bold Text, a
  /// 12-hour time needs about 80% to fit the Lock Screen card on a 375-point-wide iPhone, and
  /// even 70% is more than twice its default size.
  private static let captionScale: CGFloat = 0.7

  private var secondaryLine: some View {
    Group {
      if timestampMode != .hidden {
        if presentation.reading != nil, let sample = state.sampleTime {
          ActivityTimestamp(sample: sample, mode: timestampMode)
        } else {
          Text("Travel · True North")
        }
      }
    }
    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    .lineLimit(1).minimumScaleFactor(Self.captionScale)
  }
}

/// Lays the Lock Screen card out within the 84 to 160 point height Apple allows a Lock Screen
/// Live Activity: the card picks its layout for at most 160 points, so the system never clips it.
struct LockScreenHeight: Layout {
  static let heights: ClosedRange<CGFloat> = 84...160

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let measured =
      subviews.first?.sizeThatFits(.init(width: proposal.width, height: Self.heights.upperBound))
      ?? .zero
    // Not capped at 160 points, so a layout that overflowed would show (and fail the tests)
    // rather than be hidden here; the system would clip it.
    return CGSize(
      width: proposal.width ?? measured.width,
      height: max(measured.height, Self.heights.lowerBound))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
      proposal: .init(width: bounds.width, height: min(bounds.height, Self.heights.upperBound)))
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
    VStack(spacing: 4) {
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
        VStack(spacing: 2) {
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
      Text("Last Updated \(sample, style: .time)")
    case .elapsed:
      HStack(spacing: 4) {
        Text("Last Updated")
        Text(timerInterval: sample...Date.distantFuture, countsDown: false)
          .monospacedDigit().fixedSize()
      }
    }
  }
}
