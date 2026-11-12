import CompassCore
import Foundation
import Observation

/// The Live Activity's update frequency and auto-stop choices, kept beside the appearance. Nothing
/// is saved until a choice changes, so the standard values apply until then.
@MainActor @Observable
final class LiveActivitySettingsStore {
  static let shared = LiveActivitySettingsStore()
  nonisolated private static let key = "liveActivitySettings"
  private(set) var preferences: LiveActivityPreferences
  private let defaults: UserDefaults?

  init(defaults: UserDefaults? = UserDefaults(suiteName: AppearanceStore.suiteName)) {
    self.defaults = defaults
    preferences = LiveActivityPreferences.decode(defaults?.data(forKey: Self.key))
  }

  func update(_ change: (inout LiveActivityPreferences) -> Void) {
    var updated = preferences
    change(&updated)
    guard updated != preferences, let data = try? JSONEncoder().encode(updated) else { return }
    defaults?.set(data, forKey: Self.key)
    preferences = updated
  }
}
