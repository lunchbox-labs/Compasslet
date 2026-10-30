import CompassCore
import SwiftUI
import Synchronization
import WidgetKit

private struct CourseEntry: TimelineEntry {
  let date: Date
  let snapshot: LatestCourseSnapshot
  let generatedAt: Date
  let delivery: Int?
  var appearance = AppearanceStore.read().effective(for: .widget)
}

private struct CourseProvider: TimelineProvider {
  private static let deliveries = Mutex(0)

  func placeholder(in context: Context) -> CourseEntry {
    let date = Date()
    return CourseEntry(
      date: date, snapshot: .unavailable(at: date), generatedAt: date, delivery: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
    let date = Date()
    completion(
      CourseEntry(
        date: date, snapshot: readSnapshot(at: date),
        generatedAt: date, delivery: nil))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
    let delivery = Self.deliveries.withLock { value in
      value += 1
      return value
    }
    let date = Date()
    try? CompassDiagnostics.shared?.recordWidget(.providerInvoked, outcome: .success)
    let snapshot = readSnapshot(at: date)
    let debugging = (try? CompassDiagnostics.shared?.isEnabled()) == true
    _ = try? CompassDiagnostics.shared?.record(.widget, kind: .providerCreated)
    var entries = [
      CourseEntry(
        date: date, snapshot: snapshot, generatedAt: date, delivery: debugging ? delivery : nil)
    ]
    for transition in snapshot.transitionDates(after: date) where snapshot.status != .unavailable {
      // WidgetKit may delay delivery; every numeric layout also identifies its original sample age.
      entries.append(
        CourseEntry(
          date: transition, snapshot: snapshot.validated(at: transition),
          generatedAt: date, delivery: debugging ? delivery : nil))
    }
    completion(Timeline(entries: entries, policy: .never))
  }
  private func readSnapshot(at date: Date) -> LatestCourseSnapshot {
    guard let store = LatestCourseStore.shared else {
      try? CompassDiagnostics.shared?.recordWidget(.snapshotRead, outcome: .unavailable)
      return .unavailable(at: date)
    }
    return store.read(now: date) { result, observed in
      let outcome: CompassDiagnostics.WidgetOutcome
      switch result {
      case .success: outcome = .success
      case .missing: outcome = .missing
      case .corrupt: outcome = .corrupt
      case .failure: outcome = .failure
      }
      try? CompassDiagnostics.shared?.recordWidget(
        .snapshotRead, outcome: outcome,
        sampleAge: outcome == .success ? date.timeIntervalSince(observed.sampleTime) : nil,
        status: observed.validated(at: date).status)
    }
  }

}

struct CompassCourseWidget: Widget {
  var body: some WidgetConfiguration {
    // Preserve existing widget installations while replacing the diagnostic probe's content.
    StaticConfiguration(kind: "CompassRefreshProbe", provider: CourseProvider()) { entry in
      let snapshot = entry.snapshot.validated(at: max(Date(), entry.date))
      CourseWidgetView(entry: entry, snapshot: snapshot)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Travel Compass (Experimental)")
    .description(
      "Last recorded travel direction, with its age. Kept for up to 2 minutes. Delivery may be delayed."
    )
    .supportedFamilies([.systemSmall])
  }
}

private struct CourseWidgetView: View {
  let entry: CourseEntry
  let snapshot: LatestCourseSnapshot
  @Environment(\.dynamicTypeSize) private var systemTextSize
  @ScaledMetric(relativeTo: .caption2) private var minimumDialSize = 112
  @ScaledMetric(relativeTo: .caption2) private var debugInset = 16

  var body: some View {
    Group {
      if let bearing = snapshot.bearing {
        ViewThatFits {
          if !entry.appearance.hasReadout
            || entry.appearance.readoutTextSize(system: systemTextSize) < .xxLarge
          {
            dial(bearing: bearing, detailed: true)
            dial(bearing: bearing, detailed: false)
          }
          VStack(spacing: 4) {
            if entry.appearance.hasReadout {
              CompassReadout(bearing: bearing, appearance: entry.appearance, compact: true)
            } else {
              CompassDial(bearing: bearing, appearance: entry.appearance)
                .frame(minHeight: 60)
            }
            sampleAge
          }
          .padding(.top, entry.delivery == nil ? 0 : debugInset)
          .frame(maxWidth: .infinity)
          .overlay(alignment: .topTrailing) { debugIndicator }
        }
      } else {
        VStack(spacing: 4) {
          Text("—").font(.largeTitle.bold())
          Text(status).font(.caption)
        }
        .padding(.top, entry.delivery == nil ? 0 : debugInset)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) { debugIndicator }
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
  }

  private func dial(bearing: Double, detailed: Bool) -> some View {
    VStack(spacing: 4) {
      if detailed {
        Text("Travel · True north").font(.caption2).foregroundStyle(.secondary)
          .fixedSize()
      }
      CompassDial(bearing: bearing, appearance: entry.appearance)
        .frame(minWidth: minimumDialSize, minHeight: minimumDialSize)
      if entry.appearance.rotation == .arrow && entry.appearance.hasReadout {
        CompassReadout(bearing: bearing, appearance: entry.appearance, compact: true)
          .fixedSize(horizontal: false, vertical: true)
      }
      sampleAge
      if detailed, let delivery = entry.delivery {
        VStack(spacing: 1) {
          Text("Sample \(snapshot.sampleTime, format: .dateTime.hour().minute().second())")
          Text(
            "Provider #\(delivery) · \(entry.generatedAt, format: .dateTime.hour().minute().second())"
          )
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.secondary).fixedSize()
      }
    }
    .overlay(alignment: .topTrailing) {
      if !detailed { debugIndicator }
    }
  }

  private var sampleAge: some View {
    VStack(spacing: 1) {
      Text("Last recorded")
      Text("Updated \(snapshot.sampleTime, style: .relative) ago")
    }
    .font(.caption2).foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var debugIndicator: some View {
    if entry.delivery != nil {
      Image(systemName: "ladybug").font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func cardinal(_ bearing: Double) -> String {
    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return names[Int((bearing + 22.5) / 45) % 8]
  }

  private var accessibilitySummary: Text {
    let reading: Text
    if let bearing = snapshot.bearing {
      reading = Text(
        "\(Int(bearing.rounded()) % 360) degrees, \(cardinal(bearing)), last recorded travel direction, true north."
      )
    } else {
      reading = Text(status)
    }
    let age: Text =
      snapshot.bearing == nil
      ? reading
      : Text(
        "\(reading) Recorded \(snapshot.sampleTime, style: .relative) ago."
      )
    if let delivery = entry.delivery {
      if snapshot.bearing == nil {
        return Text(
          "\(reading) Provider \(delivery), \(entry.generatedAt, format: .dateTime.hour().minute().second())."
        )
      }
      return Text(
        "\(age) Sample \(snapshot.sampleTime, format: .dateTime.hour().minute().second()). Provider \(delivery), \(entry.generatedAt, format: .dateTime.hour().minute().second())."
      )
    }
    return age
  }

  private var status: String {
    switch snapshot.status {
    case .waiting: "Waiting for travel"
    case .slow: "Stopped or moving slowly"
    case .unreliable: "Direction uncertain"
    case .usable, .historical, .unavailable: "Travel unavailable"
    }
  }
}
