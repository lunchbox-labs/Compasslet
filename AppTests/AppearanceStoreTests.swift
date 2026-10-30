import CompassCore
import Foundation
import Testing
@testable import Compass

@Suite @MainActor
struct AppearanceStoreTests {
  @Test func savesOverridesAndRequestsReloadOnlyForChanges() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var reloads = 0
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults) { reloads += 1 }
    store.update { preferences in
      var widget = preferences.effective(for: .widget)
      widget.showDegrees = false
      preferences.setOverride(widget, for: .widget)
    }
    #expect(reloads == 1)
    #expect(!AppearanceStore.read(from: defaults).effective(for: .widget).showDegrees)
    store.update { _ in }
    #expect(reloads == 1)
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults) {}
    #expect(reopened.preferences == store.preferences)
  }

  @Test func migratesOnlyExistingPhoneArrowChoiceOnce() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "rotatesCompassDial")
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults) {}
    #expect(store.preferences.effective(for: .phone).rotation == .arrow)
    #expect(store.preferences.usesGlobal(for: .widget))
    store.update { $0.setUsesGlobal(true, for: .phone) }
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults) {}
    #expect(reopened.preferences.usesGlobal(for: .phone))
  }
}
