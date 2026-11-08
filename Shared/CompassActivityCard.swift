import CompassCore
import SwiftUI
import UIKit

/// The Live Activity on the Lock Screen and in CarPlay: the reading on one line, with Last Updated
/// beneath it. The Lock Screen card shows the reading as large as fits and stays within the 84 to
/// 160 point height Apple allows; the small card fills the size CarPlay gives it.
struct CompassActivityCard: View {
  let state: CompassActivityAttributes.ContentState
  var isStale = false
  var isSmall = false
  @Environment(\.dynamicTypeSize) private var systemTextSize

  /// The Lock Screen card's space between its edges and its text.
  static let lockScreenInsets = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)

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
            .padding(Self.lockScreenInsets)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(CompassActivityView.accessibilitySummary(state: state, isStale: isStale))
  }

  /// A reading is sized to leave room for its line beneath it: on the Lock Screen within 160
  /// points, so it always shows it, and in CarPlay within the card's height, unless even the
  /// smallest reading leaves no room. A status takes the tallest layout that fits: diagnostics
  /// (Lock Screen only), then the status between balanced lines, then (Lock Screen only) the
  /// status above its line, then the status alone, so the Lock Screen card never grows past 160
  /// points and the CarPlay card never outgrows the size CarPlay gives it. In CarPlay, a status
  /// long enough to wrap leaves no room for the line beneath it.
  @ViewBuilder private var layouts: some View {
    if presentation.reading != nil {
      if isSmall {
        GeometryReader { geometry in
          CarPlayReading(
            presentation: presentation, size: geometry.size,
            showsTimestamp: timestampMode != .hidden
          ) {
            secondaryLine
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        }
      } else {
        lockScreenReading
      }
    } else {
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
            readout()
            secondaryLine
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        // CarPlay's card has a fixed height, so a status there shrinks to fit it rather than
        // growing past it.
        if isSmall {
          readout()
        } else {
          readout().fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// The Lock Screen reading with its Last Updated line directly beneath it, where it is sized to
  /// leave room for it. Diagnostic times go beneath that when they fit too, and otherwise go.
  private var lockScreenReading: some View {
    ViewThatFits(in: .vertical) {
      if let update = state.debugUpdateTime {
        VStack(spacing: 2) {
          readingWithLine(diagnosticLines: state.sampleTime == nil ? 1 : 2)
          diagnostics(update: update)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      // The last choice, so it shows even if it doesn't fit.
      readingWithLine(diagnosticLines: 0).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func readingWithLine(diagnosticLines: Int) -> some View {
    VStack(spacing: 2) {
      readout(diagnosticLines: diagnosticLines)
      if timestampMode != .hidden {
        secondaryLine
      }
    }
  }

  private var balanced: some View {
    VStack(spacing: 2) {
      // An equal line above centers the reading against the line below.
      secondaryLine.hidden().accessibilityHidden(true)
      readout()
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
    .font(.caption2).foregroundStyle(secondaryStyle).monospacedDigit()
    .lineLimit(1).minimumScaleFactor(0.85)
  }

  /// A Lock Screen reading is as large as fits, at one size for every direction (see
  /// `ActivityReading`); a CarPlay reading is laid out by `CarPlayReading` instead. Status text
  /// wraps to a second line before it shrinks: in CarPlay to no less than half size, so two
  /// lines still fit its card at the largest text sizes, and on the Lock Screen, where it also
  /// uses a smaller style, to no less than 80%.
  private func readout(diagnosticLines: Int = 0) -> some View {
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
        ActivityReading(
          presentation: presentation,
          maximumSize: readingMaximumSize(diagnosticLines: diagnosticLines))
      }
    }
    .dynamicTypeSize(presentation.appearance.readoutTextSize(system: systemTextSize))
    .frame(maxWidth: .infinity)
    .contentTransition(.identity)
  }

  /// The largest Lock Screen reading that leaves room in 160 points for the caption lines shown
  /// beneath it at the system text size: Last Updated, and any diagnostic times.
  private func readingMaximumSize(diagnosticLines: Int) -> CGFloat {
    let lines = (timestampMode == .hidden ? 0 : 1) + diagnosticLines
    let insets = Self.lockScreenInsets.top + Self.lockScreenInsets.bottom
    // One caption line at the system text size, which the reading leaves room for beneath it.
    let captionLineHeight = systemTextSize.font(for: .caption2).lineHeight
    let captions = CGFloat(lines) * (captionLineHeight + 2)
    let height = LockScreenHeight.heights.upperBound - insets - captions
    return height / ActivityReading.lineHeight
  }

  private func readoutText(_ text: String) -> some View {
    Text(text)
      .font(Font.title2.weight(.semibold)).monospacedDigit()
      .multilineTextAlignment(.center)
  }

  /// How far the Last Updated line may shrink. At the largest text size with Bold Text, the
  /// shortest line with a 12-hour time needs about 80% to fit the 270-point card a 375-point
  /// iPhone shows with Display Zoom, so 70% leaves margin and is still twice its default size.
  static let captionScale: CGFloat = 0.7

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
    .font(.caption2).foregroundStyle(secondaryStyle).monospacedDigit()
    .lineLimit(1).minimumScaleFactor(Self.captionScale)
  }

  /// The Lock Screen card is see-through, and the system secondary colour is too faint over a
  /// bright wallpaper, so its secondary text is the primary colour at reduced opacity.
  private var secondaryStyle: AnyShapeStyle {
    if isSmall { return AnyShapeStyle(HierarchicalShapeStyle.secondary) }
    let opacity = LockScreenBackdrop.secondaryTextOpacity
    return AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(opacity))
  }
}

/// A Live Activity reading on one line at one size for every direction, so it never grows or
/// shrinks as the travel direction changes: the largest size, up to `maximumSize`, at which the
/// widest reading the appearance's fields can show fits the line. A text size below the default
/// makes it proportionally smaller; a larger one can't widen the line, so it keeps that size.
/// On a line too narrow even for `minimumSize`, the reading drops to a shorter form, the field
/// the appearance's If Both Don’t Fit setting keeps first.
struct ActivityReading: View {
  let presentation: CompassActivityReading
  let maximumSize: CGFloat
  var minimumSize: CGFloat = 34
  @Environment(\.dynamicTypeSize) private var textSize

  /// A line's height as a multiple of its font size, with a little margin over the system font's.
  static let lineHeight: CGFloat = 1.22
  /// The step between the sizes tried, small enough that the chosen size nearly fills the line.
  static let sizeStep: CGFloat = 2
  /// Larger than any iPhone's line allows, so fewer sizes are tried.
  static let largestSize: CGFloat = 96

  /// The sizes tried, largest first.
  static func sizes(minimum: CGFloat, maximum: CGFloat) -> [CGFloat] {
    let largest = max(minimum, min(maximum, largestSize).rounded(.down))
    var sizes = Array(stride(from: largest, through: minimum, by: -sizeStep))
    // The step can pass over the minimum; it's always tried before the shorter form.
    if sizes.last != minimum { sizes.append(minimum) }
    return sizes
  }

  var body: some View {
    let standard = DynamicTypeSize.large.font(for: .largeTitle).pointSize
    let scale = min(textSize.font(for: .largeTitle).pointSize / standard, 1)
    ViewThatFits(in: .horizontal) {
      ForEach(Self.sizes(minimum: minimumSize, maximum: maximumSize), id: \.self) { size in
        // The widest reading, hidden and flat, sets the line's width at this size, so the size
        // chosen fits every direction, not just the one shown.
        VStack(spacing: 0) {
          text(presentation.bearing, size: size * scale)
          text(presentation.widestBearing, size: size).fixedSize().hidden().frame(height: 0)
        }
      }
      ForEach(Array(presentation.bearingCandidates.dropFirst()), id: \.self) { candidate in
        text(candidate, size: minimumSize * scale).minimumScaleFactor(0.8)
      }
    }
    .contentTransition(.identity)
  }

  private func text(_ text: String, size: CGFloat) -> some View {
    Text(verbatim: text)
      .font(.system(size: size, weight: .semibold)).monospacedDigit()
      .lineLimit(1)
  }
}

/// The CarPlay reading as large as the card's height allows, at one size for every direction,
/// with its Last Updated line beneath it. When even the smallest reading would leave no room for
/// the line, as at the largest text sizes, the reading goes alone and fills the height. The
/// smallest reading is the title size the card has always used, so a larger text size still
/// enlarges it; on a line too narrow for it, the reading drops to its shorter form.
struct CarPlayReading<Line: View>: View {
  let presentation: CompassActivityReading
  /// The card's size inside its insets.
  let size: CGSize
  let showsTimestamp: Bool
  @ViewBuilder let line: Line
  @Environment(\.dynamicTypeSize) private var systemTextSize

  /// The reading's size range, and whether its line fits beneath it.
  struct Sizing: Equatable {
    var maximum: CGFloat
    var minimum: CGFloat
    var showsLine: Bool
  }

  static func sizing(
    height: CGFloat, readoutSize: DynamicTypeSize, systemTextSize: DynamicTypeSize,
    showsTimestamp: Bool
  ) -> Sizing {
    let minimum = max(
      DynamicTypeSize.large.font(for: .title2).pointSize,
      readoutSize.font(for: .title2).pointSize)
    let lineHeight = showsTimestamp ? systemTextSize.font(for: .caption2).lineHeight + 2 : 0
    let withLine = (height - lineHeight) / ActivityReading.lineHeight
    let showsLine = showsTimestamp && withLine >= minimum
    return Sizing(
      maximum: showsLine ? withLine : height / ActivityReading.lineHeight, minimum: minimum,
      showsLine: showsLine)
  }

  var body: some View {
    let readoutSize = presentation.appearance.readoutTextSize(system: systemTextSize)
    let sizing = Self.sizing(
      height: size.height, readoutSize: readoutSize, systemTextSize: systemTextSize,
      showsTimestamp: showsTimestamp)
    VStack(spacing: 2) {
      ActivityReading(
        presentation: presentation,
        maximumSize: sizing.maximum,
        minimumSize: sizing.minimum
      )
      .dynamicTypeSize(readoutSize)
      if sizing.showsLine {
        line
      }
    }
  }
}

extension CompassActivityReading {
  /// The widest reading the appearance's fields can show, for sizing a reading once for every
  /// direction: "NW" is the widest point, and monospaced digits make every three-digit angle as
  /// wide as any other.
  var widestBearing: String {
    [
      appearance.showDirection ? Self.widestPoint.abbreviation : nil,
      appearance.showDegrees ? "000°" : nil,
    ].compactMap { $0 }.joined(separator: " ")
  }

  static let widestPoint = CompassPoint.northwest
}

extension DynamicTypeSize {
  /// The system font for a text style at this text size.
  func font(for style: UIFont.TextStyle) -> UIFont {
    UIFont.preferredFont(
      forTextStyle: style,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(self)))
  }
}

extension View {
  /// Puts the see-through Lock Screen backdrop behind the card when `isActive`.
  func lockScreenBackdrop(isActive: Bool) -> some View {
    modifier(LockScreenBackdropModifier(isActive: isActive))
  }
}

/// Tints the Lock Screen card black in the dark look and white in the light look, so the
/// wallpaper shows through. Drawn by the card rather than with the system's background tint,
/// so it changes with the text colours whenever the Lock Screen changes the card's look.
struct LockScreenBackdropModifier: ViewModifier {
  let isActive: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let opacity = LockScreenBackdrop.opacity(
      reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
    let tint = colorScheme == .dark ? Color.black : Color.white
    content.background(isActive ? tint.opacity(opacity) : Color.clear)
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
  @Environment(\.dynamicTypeSize) private var systemTextSize

  /// The largest reading in the expanded Dynamic Island, whose regions have fixed bounds.
  static let maximumReadingSize: CGFloat = 44

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
        ActivityReading(
          presentation: presentation, maximumSize: Self.maximumReadingSize, minimumSize: 28
        )
        .dynamicTypeSize(presentation.appearance.readoutTextSize(system: systemTextSize))
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

  /// The space between the label and the time.
  static let spacing: CGFloat = 4
  /// The widest the elapsed timer gets. An ended Live Activity can stay on the Lock Screen for
  /// hours, and the digits are monospaced.
  static let widestTimer = "00:00:00"

  var body: some View {
    switch mode {
    case .hidden:
      EmptyView()
    case .time:
      // With Display Zoom a 375-point iPhone's card is only 270 points wide, too narrow for the
      // full line at the largest text sizes even at its smallest scale.
      ViewThatFits(in: .horizontal) {
        Text("Last Updated \(sample, style: .time)")
        Text("Updated \(sample, style: .time)")
      }
    case .elapsed:
      // The timer keeps its full size, so when the line is too wide the label shortens and
      // then goes, rather than shrinking beside it.
      ViewThatFits(in: .horizontal) {
        elapsed(label: "Last Updated")
        elapsed(label: "Updated")
        elapsed(label: nil)
      }
    }
  }

  /// The system advances the timer without a new layout, so the line is measured with the
  /// widest the timer can grow to, and a label chosen for "0:12" still fits at "10:00:00".
  private func elapsed(label: LocalizedStringKey?) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: Self.spacing) {
        if let label { Text(label) }
        Text(timerInterval: sample...Date.distantFuture, countsDown: false)
          .monospacedDigit().fixedSize()
      }
      HStack(spacing: Self.spacing) {
        if let label { Text(label) }
        Text(verbatim: Self.widestTimer).monospacedDigit().fixedSize()
      }
      .hidden().frame(height: 0)
    }
  }
}
