import Foundation

/// How often a drive sends its Live Activity a changed direction, at most. Raw values are stable
/// storage identifiers and give the interval in seconds; a value no longer offered, such as the 30
/// seconds of early test builds, reads as the default.
public enum LiveActivityUpdateFrequency: Int, CaseIterable, Codable, Sendable {
  case everySecond = 1
  case everyFiveSeconds = 5
  case everyFifteenSeconds = 15

  /// The shortest time between two changed directions sent to the Live Activity.
  public var interval: TimeInterval { TimeInterval(rawValue) }
}

/// How long a drive keeps running after the car leaves, before it ends on its own. Raw values are
/// stable storage identifiers and give the delay in seconds, with 0 for never.
public enum LiveActivityAutoStop: Int, CaseIterable, Codable, Sendable {
  case oneMinute = 60
  case fiveMinutes = 300
  case fifteenMinutes = 900
  case never = 0

  /// How long after the car leaves the drive ends, or nil when it runs until it is ended or
  /// reaches the drive's own limit.
  public var delay: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
}

/// How a drive's Live Activity updates and when it ends on its own. The standard values keep the
/// behaviour from before these settings existed.
public struct LiveActivityPreferences: Codable, Hashable, Sendable {
  public var updateFrequency: LiveActivityUpdateFrequency = .everySecond
  public var autoStop: LiveActivityAutoStop = .oneMinute

  public init() {}

  /// The update frequency keeps the key test builds saved it under, so their choices still apply.
  private enum CodingKeys: String, CodingKey {
    case updateFrequency = "refreshRate"
    case autoStop
  }

  /// Decodes saved values, keeping the standard choice for a key that is missing or holds a value
  /// this version doesn't know.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let standard = Self()
    updateFrequency =
      (try? values.decodeIfPresent(LiveActivityUpdateFrequency.self, forKey: .updateFrequency))
      ?? standard.updateFrequency
    autoStop =
      (try? values.decodeIfPresent(LiveActivityAutoStop.self, forKey: .autoStop))
      ?? standard.autoStop
  }

  /// Loads persisted choices, recovering the standard ones from missing or corrupt data.
  public static func decode(_ data: Data?) -> Self {
    guard let data, let preferences = try? JSONDecoder().decode(Self.self, from: data) else {
      return Self()
    }
    return preferences
  }
}
