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
  @ScaledMetric(relativeTo: .caption2) private var minimumDialSize = 112
  @ScaledMetric(relativeTo: .caption2) private var debugInset = 16

  var body: some View {
    Group {
      if let bearing = snapshot.bearing {
        ViewThatFits {
          dial(bearing: bearing, detailed: true)
          dial(bearing: bearing, detailed: false)
          VStack(spacing: 4) {
            Text("\(cardinal(bearing)) \(Int(bearing.rounded()) % 360)°")
              .font(.title2).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
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
      CourseDial(bearing: bearing)
        .frame(minWidth: minimumDialSize, minHeight: minimumDialSize)
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
          Text(label).font(.system(size: max(11, diameter * 0.085), weight: .semibold))
            .foregroundStyle(index == 0 ? Color.red : Color.secondary)
            .offset(x: radius * 0.7 * CGFloat(cos(angle)), y: radius * 0.7 * CGFloat(sin(angle)))
        }
        Image(systemName: "triangle.fill")
          .font(.system(size: diameter * 0.075)).foregroundStyle(.tint)
          .rotationEffect(.degrees(180))
          .offset(y: -radius)
        VStack(spacing: 0) {
          Text("\(Int(bearing.rounded()) % 360)°")
            .font(.system(size: max(20, diameter * 0.19))).monospacedDigit()
          Text(cardinal).font(.system(size: max(13, diameter * 0.11), weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: diameter * 0.6)
      }
      .frame(width: diameter, height: diameter)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(Int(bearing.rounded()) % 360) degrees, \(cardinal), last known travel direction")
  }
}
