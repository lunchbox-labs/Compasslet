import CompassCore
import Foundation
import Observation

/// Saves the appearance settings in the App Group's defaults suite. The suite is the app's own
/// storage: the Live Activity gets its appearance from the activity's content state, and nothing
/// else reads the suite. It stays because moving to standard defaults would need a migration of
/// saved settings.
@MainActor @Observable
final class AppearanceStore {
  static let shared = AppearanceStore()
  nonisolated static let suiteName = "group.dev.lunchbox-labs.carplay-compass"
  nonisolated private static let key = "compassAppearance"
  private(set) var preferences: AppearancePreferences
  private let defaults: UserDefaults?

  init(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
    self.defaults = defaults
    preferences = Self.read(from: defaults)
    if defaults?.data(forKey: Self.key) == nil, let data = try? JSONEncoder().encode(preferences) {
      defaults?.set(data, forKey: Self.key)
    }
  }

  nonisolated static func read(
    from defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
  ) -> AppearancePreferences {
    AppearancePreferences.decode(defaults?.data(forKey: key))
  }

  func update(_ change: (inout AppearancePreferences) -> Void) {
    var updated = preferences
    change(&updated)
    guard updated != preferences, let data = try? JSONEncoder().encode(updated) else { return }
    defaults?.set(data, forKey: Self.key)
    preferences = updated
  }
}
