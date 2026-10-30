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
        date: date, snapshot: LatestCourseStore.shared?.read(now: date) ?? .unavailable(at: date),
        generatedAt: date, delivery: nil))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
    let delivery = Self.deliveries.withLock { value in
      value += 1
      return value
    }
    let date = Date()
    let snapshot = LatestCourseStore.shared?.read(now: date) ?? .unavailable(at: date)
    let debugging = (try? CompassDiagnostics.shared?.isEnabled()) == true
    _ = try? CompassDiagnostics.shared?.record(.widget, kind: .providerCreated)
    var entries = [
      CourseEntry(
        date: date, snapshot: snapshot, generatedAt: date, delivery: debugging ? delivery : nil)
    ]
    if snapshot.status != .unavailable, snapshot.expiry > date {
      // This requests expiry rendering; WidgetKit can delay delivering any timeline entry.
      entries.append(
        CourseEntry(
          date: snapshot.expiry, snapshot: .unavailable(at: snapshot.expiry),
          generatedAt: date, delivery: debugging ? delivery : nil))
    }
    completion(Timeline(entries: entries, policy: .never))
  }
}

struct CompassCourseWidget: Widget {
  var body: some WidgetConfiguration {
    // Preserve existing widget installations while replacing the diagnostic probe's content.
    StaticConfiguration(kind: "CompassRefreshProbe", provider: CourseProvider()) { entry in
      let snapshot = entry.snapshot.validated(at: Date())
      CourseWidgetView(entry: entry, snapshot: snapshot)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Travel Compass (Experimental)")
    .description("Sampled vehicle travel direction. Updates and expiry may be delayed by CarPlay.")
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
            Text("Last known").font(.caption2).foregroundStyle(.secondary)
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
      Text("Last known").font(.caption2).foregroundStyle(.secondary).fixedSize()
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
        "\(Int(bearing.rounded()) % 360) degrees, \(cardinal(bearing)), last known travel direction, true north."
      )
    } else {
      reading = Text(status)
    }
    if let delivery = entry.delivery {
      if snapshot.bearing == nil {
        return Text(
          "\(reading) Provider \(delivery), \(entry.generatedAt, format: .dateTime.hour().minute().second())."
        )
      }
      return Text(
        "\(reading) Sample \(snapshot.sampleTime, format: .dateTime.hour().minute().second()). Provider \(delivery), \(entry.generatedAt, format: .dateTime.hour().minute().second())."
      )
    }
    return reading
  }

  private var status: String {
    switch snapshot.status {
    case .waiting: "Waiting for travel"
    case .slow: "Stopped or moving slowly"
    case .unreliable: "Direction uncertain"
    case .usable, .unavailable: "Travel unavailable"
    }
  }
}
