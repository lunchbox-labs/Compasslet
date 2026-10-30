import SwiftUI
import Synchronization
import WidgetKit

private struct CourseEntry: TimelineEntry {
  let date: Date
  let snapshot: LatestCourseSnapshot
  let generatedAt: Date
  let delivery: Int?
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
      VStack(spacing: 3) {
        if let bearing = snapshot.bearing {
          let cardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
          Text(cardinals[Int((bearing + 22.5) / 45) % 8]).font(.largeTitle.bold())
          Text("\(Int(bearing.rounded()) % 360)°").font(.title2).monospacedDigit()
          Text("Travel · True north").font(.caption2)
          Text("Sampled \(snapshot.sampleTime, format: .dateTime.hour().minute().second())")
            .font(.caption2).monospacedDigit()
        } else {
          Text("—").font(.largeTitle.bold())
          Text(Self.status(snapshot.status)).font(.caption)
        }
        if let delivery = entry.delivery {
          Text(
            "Provider #\(delivery) · \(entry.generatedAt, format: .dateTime.hour().minute().second())"
          )
          .font(.caption2).monospacedDigit()
        }
      }
      .accessibilityElement(children: .combine)
      .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Travel Compass (Experimental)")
    .description("Sampled vehicle travel direction. Updates and expiry may be delayed by CarPlay.")
    .supportedFamilies([.systemSmall])
  }

  private static func status(_ status: LatestCourseSnapshot.Status) -> String {
    switch status {
    case .waiting: "Waiting for travel"
    case .slow: "Stopped or moving slowly"
    case .unreliable: "Direction uncertain"
    case .usable, .unavailable: "Travel unavailable"
    }
  }
}
