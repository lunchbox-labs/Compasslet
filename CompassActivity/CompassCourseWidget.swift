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
      VStack(spacing: 4) {
        if let bearing = snapshot.bearing {
          Text("Travel · True north").font(.caption2).foregroundStyle(.secondary)
          CourseDial(bearing: bearing)
          Text("Last known").font(.caption2).foregroundStyle(.secondary)
        } else {
          VStack(spacing: 4) {
            Text("—").font(.largeTitle.bold())
            Text(Self.status(snapshot.status)).font(.caption)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let delivery = entry.delivery {
          VStack(spacing: 1) {
            if snapshot.bearing != nil {
              Text("Sample \(snapshot.sampleTime, format: .dateTime.hour().minute().second())")
            }
            Text(
              "Provider #\(delivery) · \(entry.generatedAt, format: .dateTime.hour().minute().second())"
            )
          }
          .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
          .lineLimit(1).minimumScaleFactor(0.7)
        }
      }
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct CourseDial: View {
  let bearing: Double

  private var cardinal: String {
    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return names[Int((bearing + 22.5) / 45) % 8]
  }

  var body: some View {
    GeometryReader { geometry in
      let diameter = max(0, min(geometry.size.width, geometry.size.height) - 12)
      let radius = diameter / 2
      ZStack {
        Circle().stroke(.quaternary, lineWidth: 1)
        ForEach(0..<72) { index in
          Capsule()
            .fill(index % 9 == 0 ? Color.primary : Color.secondary)
            .frame(
              width: index % 9 == 0 ? 2 : 1, height: diameter * (index % 9 == 0 ? 0.06 : 0.025)
            )
            .offset(y: -radius * 0.9)
            .rotationEffect(.degrees(Double(index) * 5 - bearing))
        }
        ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, label in
          let angle = (Double(index) * 90 - bearing - 90) * .pi / 180
          Text(label).font(.system(size: diameter * 0.085, weight: .semibold))
            .foregroundStyle(index == 0 ? Color.red : Color.secondary)
            .offset(x: radius * 0.7 * CGFloat(cos(angle)), y: radius * 0.7 * CGFloat(sin(angle)))
        }
        Image(systemName: "triangle.fill")
          .font(.system(size: diameter * 0.075)).foregroundStyle(.tint)
          .rotationEffect(.degrees(180))
          .offset(y: -radius)
        VStack(spacing: 0) {
          Text("\(Int(bearing.rounded()) % 360)°")
            .font(.system(size: diameter * 0.19)).monospacedDigit()
          Text(cardinal).font(.system(size: diameter * 0.11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .frame(width: diameter * 0.5)
      }
      .frame(width: diameter, height: diameter)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(Int(bearing.rounded()) % 360) degrees, \(cardinal), last known travel direction")
  }
}
