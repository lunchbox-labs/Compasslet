import CompassCore
import Foundation
import Testing
@testable import Compass

@Suite @MainActor
struct AppearanceStoreTests {
  @Test func savesOverridesAndPreservesUnchangedPreferences() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    store.update { preferences in
      var activity = preferences.effective(for: .activity)
      activity.showDegrees = false
      preferences.setOverride(activity, for: .activity)
    }
    #expect(!AppearanceStore.read(from: defaults).effective(for: .activity).showDegrees)
    let saved = store.preferences
    store.update { _ in }
    #expect(store.preferences == saved)
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(reopened.preferences == saved)
  }

  @Test func everyReadoutSizeMapsToItsDynamicTypeCategoryInOrder() {
    let mapped = ReadoutTextSize.allCases.map(\.dynamicTypeSize)
    #expect(mapped == mapped.sorted())
    #expect(Set(mapped).count == mapped.count)
    #expect(ReadoutTextSize.xxxLarge.dynamicTypeSize == .xxxLarge)
    #expect(ReadoutTextSize.accessibility1.dynamicTypeSize == .accessibility1)
    #expect(ReadoutTextSize.accessibility5.dynamicTypeSize == .accessibility5)
    #expect(ReadoutTextSize.accessibility5.dynamicTypeSize.isAccessibilitySize)
    #expect(!ReadoutTextSize.xxxLarge.dynamicTypeSize.isAccessibilitySize)
    #expect(Set(ReadoutTextSize.allCases.map(\.title)).count == ReadoutTextSize.allCases.count)
  }

  @Test func migratesOnlyExistingPhoneArrowChoiceOnce() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "rotatesCompassDial")
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(store.preferences.effective(for: .phone).rotation == .arrow)
    #expect(store.preferences.usesGlobal(for: .activity))
    store.update { $0.setUsesGlobal(true, for: .phone) }
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(reopened.preferences.usesGlobal(for: .phone))
  }
}
