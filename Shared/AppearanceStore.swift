import Combine
import CompassCore
import Foundation

@MainActor
final class AppearanceStore: ObservableObject {
  static let shared = AppearanceStore()
  nonisolated static let suiteName = "group.dev.lunchbox-labs.carplay-compass"
  nonisolated private static let key = "compassAppearance"
  @Published private(set) var preferences: AppearancePreferences
  private let defaults: UserDefaults?

  init(
    defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
    legacyDefaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    var initial = Self.read(from: defaults)
    if defaults?.data(forKey: Self.key) == nil,
      let rotates = legacyDefaults.object(forKey: "rotatesCompassDial") as? Bool, !rotates
    {
      // Preserve the existing phone-only choice without changing the other surfaces.
      var phone = initial.effective(for: .phone)
      phone.rotation = .arrow
      initial.setOverride(phone, for: .phone)
    }
    preferences = initial
    if defaults?.data(forKey: Self.key) == nil, let data = try? JSONEncoder().encode(initial) {
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
    // Preferences do not change any sensor timestamp.
  }
}
