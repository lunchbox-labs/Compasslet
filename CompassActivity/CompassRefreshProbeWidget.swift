import OSLog
import SwiftUI
import Synchronization
import WidgetKit

private struct RefreshProbeEntry: TimelineEntry {
  let date: Date
  let delivery: Int?
}

private struct RefreshProbeProvider: TimelineProvider {
  // No shared container or persistence: this counter resets with the extension process.
  private static let deliveries = Mutex(0)
  private static let log = Logger(
    subsystem: "dev.lunchbox-labs.carplay-compass", category: "WidgetRefreshProbe")

  func placeholder(in context: Context) -> RefreshProbeEntry {
    RefreshProbeEntry(date: .now, delivery: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (RefreshProbeEntry) -> Void) {
    completion(placeholder(in: context))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RefreshProbeEntry>) -> Void)
  {
    let delivery = Self.deliveries.withLock { value in
      value += 1
      return value
    }
    let date = Date()
    Self.log.info("delivery #\(delivery) at \(date.timeIntervalSince1970)")
    completion(
      Timeline(entries: [RefreshProbeEntry(date: date, delivery: delivery)], policy: .never))
  }
}

struct CompassRefreshProbeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CompassRefreshProbe", provider: RefreshProbeProvider()) { entry in
      VStack(alignment: .leading, spacing: 4) {
        Text("Refresh probe").font(.caption)
        if let delivery = entry.delivery {
          Text("#\(delivery)").font(.largeTitle.bold()).monospacedDigit()
          Text(entry.date, format: .dateTime.hour().minute().second())
            .font(.caption).monospacedDigit()
          Text("Provider time · counter resets").font(.caption2)
        } else {
          Text("Waiting for timeline").font(.headline)
        }
      }
      .accessibilityElement(children: .combine)
      .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Compass Refresh Probe")
    .description("Experimental refresh timing, not a compass reading. Counters reset on restart.")
    .supportedFamilies([.systemSmall])
  }
}
