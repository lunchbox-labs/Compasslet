import ActivityKit
import Foundation
import CompassCore

struct CompassActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    var bearing: Double?
    var status: Status
    var sampleTime: Date?
    var expiry: Date?
    var debugUpdateTime: Date? = nil
    var appearance: AppearanceValues? = nil
  }

  enum Status: String, Codable, Hashable, Sendable {
    case waiting, usable, slow, unreliable, unavailable
  }
}

/// What one activity presentation shows and speaks for a content state, so every presentation
/// describes a state the same way and the mapping can be tested without a view context.
struct CompassActivityReading {
  /// A usable retained reading; nil for every waiting, stale, unavailable or interrupted state.
  struct Reading: Equatable {
    let point: CompassPoint
    let roundedDegrees: Int
    var degrees: String { "\(roundedDegrees)°" }
  }

  let reading: Reading?
  /// The visible status line; a system-stale activity is unavailable whatever its payload says.
  let status: String
  let appearance: AppearanceValues

  init(state: CompassActivityAttributes.ContentState, isStale: Bool) {
    appearance = (state.appearance ?? AppearanceValues()).requiringReadout()
    if !isStale, state.status == .usable, let degrees = state.bearing, degrees.isFinite,
      (0..<360).contains(degrees), let point = CompassPoint(degrees: degrees)
    {
      reading = Reading(point: point, roundedDegrees: Int(degrees.rounded()) % 360)
    } else {
      reading = nil
    }
    if isStale {
      status = "Travel unavailable"
    } else {
      status =
        switch state.status {
        case .waiting: "Waiting for travel"
        case .usable, .unavailable: "Travel unavailable"
        case .slow: "Move steadily to show travel"
        case .unreliable: "Travel direction uncertain"
        }
    }
  }

  /// The visible reading, honoring the appearance's field choices; a dash without a reading.
  var bearing: String {
    guard let reading else { return "—" }
    return [
      appearance.showDirection ? reading.point.abbreviation : nil,
      appearance.showDegrees ? reading.degrees : nil,
    ].compactMap { $0 }.joined(separator: " ")
  }

  /// The visible reading followed by its shorter forms, degrees then direction, when both fields
  /// are shown, so a small presentation can shorten before shrinking; nothing without a reading.
  var bearingCandidates: [String] {
    guard let reading else { return [] }
    guard appearance.showDirection && appearance.showDegrees else { return [bearing] }
    return [bearing, reading.degrees, reading.point.abbreviation]
  }

  /// The spoken description without the sample time, which a view appends in the user's format.
  var spokenDescription: String {
    guard let reading else { return "\(status), travel direction, true north" }
    return
      "\(reading.roundedDegrees) degrees, \(reading.point.name), last recorded travel direction, true north"
  }
}
