import Foundation

/// Presentations that can follow global appearance or store a whole-surface override.
public enum AppearanceSurface: String, CaseIterable, Codable, Sendable {
  case phone, activity
}

/// Position of the four cardinal rim labels, independent of center text.
public enum CardinalLabels: String, CaseIterable, Codable, Sendable {
  case inside, outside, hidden
}

/// Which part of the dial follows the current bearing.
public enum DialRotation: String, CaseIterable, Codable, Sendable {
  case dial, arrow
}

/// Number of interior marks between adjacent cardinal major ticks.
public enum MinorTicks: Int, CaseIterable, Codable, Sendable {
  case none = 0, five = 5, eight = 8, seventeen = 17

  /// Four major ticks, with the selected number of interior marks in each quarter.
  public var angles: [Double] {
    (0..<(4 * (rawValue + 1))).map { Double($0) * 90 / Double(rawValue + 1) }
  }
}

/// The twelve Dynamic Type categories available for a custom readout size, in ascending order.
///
/// Raw values are stable storage identifiers; the five accessibility categories extend the
/// original seven standard categories so saved choices keep their meaning.
public enum ReadoutTextSize: Int, CaseIterable, Codable, Sendable {
  case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
  case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

  /// The largest standard category; every later case is an accessibility category.
  public static let largestStandard: Self = .xxxLarge

  /// Whether this is one of the system's accessibility text size categories.
  public var isAccessibilitySize: Bool { rawValue > Self.largestStandard.rawValue }
}

/// Display-only choices; never contains sensor samples or validity timestamps.
public struct AppearanceValues: Codable, Hashable, Sendable {
  /// Shows the abbreviated direction in the readout.
  public var showDirection = true
  /// Shows numerical degrees in the readout.
  public var showDegrees = true
  /// Follows the presentation environment's Dynamic Type category when enabled.
  public var useSystemTextSize = true
  /// Readout-only category used when system sizing is disabled.
  public var customTextSize: ReadoutTextSize = .large
  /// Interior tick density in each quarter.
  public var minorTicks: MinorTicks = .seventeen
  /// Cardinal rim-label placement.
  public var labels: CardinalLabels = .inside
  /// Rotating dial or rotating arrow.
  public var rotation: DialRotation = .dial

  /// Creates the standard appearance.
  public init() {}

  /// Whether any central reading is visible.
  public var hasReadout: Bool { showDirection || showDegrees }

  /// Recovers direction-only presentation if both fields were disabled.
  public func requiringReadout() -> Self {
    var value = self
    if !value.hasReadout { value.showDirection = true }
    return value
  }
}

/// One optional override per surface; nil means follow the current global values.
public struct AppearancePreferences: Codable, Hashable, Sendable {
  /// Shared values used by surfaces without an override.
  public private(set) var global = AppearanceValues()
  private var phone: AppearanceValues?
  private var activity: AppearanceValues?

  /// Creates the standard appearance.
  public init() {}

  /// Whether a surface follows subsequent global changes.
  public func usesGlobal(for surface: AppearanceSurface) -> Bool {
    override(for: surface) == nil
  }

  /// Resolves a surface, preserving the text-only activity constraint.
  public func effective(for surface: AppearanceSurface) -> AppearanceValues {
    let value = override(for: surface) ?? global.requiringReadout()
    return surface == .activity ? value.requiringReadout() : value
  }

  /// Updates shared values while retaining a usable Live Activity reading.
  public mutating func setGlobal(_ value: AppearanceValues) {
    global = value.requiringReadout()
  }

  /// Discards the override, or starts a fresh copy of the current global values.
  public mutating func setUsesGlobal(_ usesGlobal: Bool, for surface: AppearanceSurface) {
    // Starting a new customization always copies today's global values.
    set(usesGlobal ? nil : global.requiringReadout(), for: surface)
  }

  /// Stores a complete local choice, enforcing the activity readout constraint.
  public mutating func setOverride(_ value: AppearanceValues, for surface: AppearanceSurface) {
    set(surface == .activity ? value.requiringReadout() : value, for: surface)
  }

  /// Loads persisted choices, recovering safely from unsupported or corrupt data.
  public static func decode(_ data: Data?) -> Self {
    guard let data, var preferences = try? JSONDecoder().decode(Self.self, from: data) else {
      return Self()
    }
    preferences.global = preferences.global.requiringReadout()
    preferences.activity = preferences.activity?.requiringReadout()
    return preferences
  }

  private func override(for surface: AppearanceSurface) -> AppearanceValues? {
    switch surface {
    case .phone: phone
    case .activity: activity
    }
  }

  private mutating func set(_ value: AppearanceValues?, for surface: AppearanceSurface) {
    switch surface {
    case .phone: phone = value
    case .activity: activity = value
    }
  }
}
