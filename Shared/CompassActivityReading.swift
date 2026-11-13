import CompassCore
import Foundation

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
  /// Each is kept about as short as "Start moving" so it fits the Live Activity at the largest
  /// text sizes with Bold Text.
  let status: String
  /// The status as VoiceOver speaks it, in full where the visible line is shortened.
  let spokenStatus: String
  let appearance: AppearanceValues

  init(state: CompassActivityAttributes.ContentState, isStale: Bool) {
    appearance = (state.appearance ?? AppearanceValues()).requiringReadout()
    if !isStale, state.status == .usable, let degrees = state.bearing, degrees.isFinite,
      (0..<360).contains(degrees), let angle = CompassAngle(degrees: degrees)
    {
      reading = Reading(point: CompassPoint(angle: angle), roundedDegrees: angle.roundedDegrees)
    } else {
      reading = nil
    }
    let (visible, spoken): (String, String) =
      if isStale {
        ("Travel unavailable", "Travel unavailable")
      } else {
        switch state.status {
        case .waiting: ("Start moving", "Start moving")
        case .usable, .unavailable: ("Travel unavailable", "Travel unavailable")
        case .slow: ("Keep moving", "Keep moving to show travel direction")
        case .unreliable: ("Finding…", "Finding travel direction")
        }
      }
    status = visible
    spokenStatus = spoken
  }

  /// The visible reading, honoring the appearance's field choices; a dash without a reading.
  var bearing: String {
    guard let reading else { return "—" }
    return [
      appearance.showDirection ? reading.point.abbreviation : nil,
      appearance.showDegrees ? reading.degrees : nil,
    ].compactMap { $0 }.joined(separator: " ")
  }

  /// The visible reading followed by its shorter forms when both fields are shown, the one the
  /// appearance keeps first, so a small presentation can shorten before shrinking; nothing
  /// without a reading.
  var bearingCandidates: [String] {
    guard let reading else { return [] }
    guard appearance.showDirection && appearance.showDegrees else { return [bearing] }
    let degrees = reading.degrees
    let direction = reading.point.abbreviation
    return switch appearance.shortReadout {
    case .degrees: [bearing, degrees, direction]
    case .direction: [bearing, direction, degrees]
    }
  }

  /// The one field the compact Dynamic Island has room for: the only one shown, or the one the
  /// appearance keeps first when both are; a dash without a reading.
  var compactBearing: String {
    guard let reading else { return "—" }
    guard appearance.showDirection && appearance.showDegrees else { return bearing }
    return switch appearance.shortReadout {
    case .degrees: reading.degrees
    case .direction: reading.point.abbreviation
    }
  }

  /// The spoken description without the sample time, which a view appends in the user's format.
  var spokenDescription: String {
    guard let reading else { return spokenStatus }
    return
      "\(reading.roundedDegrees) degrees, \(reading.point.name), last recorded travel direction"
  }
}
