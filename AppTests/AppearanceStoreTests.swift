import CompassCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Compass

@Suite @MainActor
struct AppearanceStoreTests {
  @Test func phonePreviewRendersDialChoicesAndReducedMotionFallback() throws {
    func render(_ value: AppearanceValues, reduceMotion: Bool = false) throws -> UIImage {
      let renderer = ImageRenderer(
        content: AppearancePreview(surface: .phone, appearance: value, reduceMotion: reduceMotion)
          .frame(width: 280)
          .environment(\.dynamicTypeSize, .large)
          .environment(\.colorScheme, .light))
      renderer.scale = 1
      return try #require(renderer.uiImage)
    }
    let initial = AppearanceValues()
    let original = try #require(render(initial).pngData())
    var changed = initial
    changed.minorTicks = .none
    #expect(try #require(render(changed).pngData()) != original)
    changed = initial
    changed.labels = .hidden
    #expect(try #require(render(changed).pngData()) != original)
    changed = initial
    changed.rotation = .arrow
    #expect(try #require(render(changed).pngData()) != original)
    changed.showDirection = false
    changed.showDegrees = false
    let steady = try render(changed, reduceMotion: true)
    let restored = try render(changed.requiringReadout(), reduceMotion: true)
    #expect(steady.pngData() == restored.pngData())
    changed.reducedMotionDial = .rotatingDial
    let dial = try render(changed, reduceMotion: true)
    #expect(dial.size.height > steady.size.height)
    // Keep the Dial is a static example, identical to the ordinary dial preview.
    #expect(try render(changed).pngData() == dial.pngData())
  }

  @Test func readoutSelectionPreservesHiddenLegacyValuesUntilExplicitChoice() throws {
    let name = "readout-editor-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    store.update { preferences in
      var hidden = preferences.effective(for: .phone)
      hidden.showDirection = false
      hidden.showDegrees = false
      hidden.rotation = .arrow
      preferences.setOverride(hidden, for: .phone)
    }
    let phone = AppearanceReadoutControl(surface: .phone, store: store)
    #expect(phone.selection == nil)
    #expect(!AppearanceStore.read(from: defaults).effective(for: .phone).hasReadout)
    for mode in ReadoutMode.allCases {
      phone.select(mode)
      #expect(phone.selection == mode)
      let saved = AppearanceStore.read(from: defaults)
      #expect(saved.effective(for: .phone).readoutMode == mode)
      #expect(saved.effective(for: .phone).rotation == .arrow)
      #expect(saved.global.readoutMode == .both)
      #expect(saved.usesGlobal(for: .activity))
    }
    let global = AppearanceReadoutControl(surface: nil, store: store)
    let activity = AppearanceReadoutControl(surface: .activity, store: store)
    global.select(.degrees)
    #expect(activity.selection == .degrees)
    #expect(phone.selection == .both)
    store.update { $0.setUsesGlobal(true, for: .phone) }
    #expect(phone.selection == .degrees)
    global.select(.direction)
    #expect(phone.selection == .direction)
    activity.select(.both)
    #expect(activity.selection == .both)
    #expect(global.selection == .direction)
  }

  @Test func editorSelectionsPersistImmediatelyAndReadCurrentStoreValues() throws {
    let name = "appearance-editor-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    let global = AppearanceOptionEditor(surface: nil, option: .minorTicks, store: store)
    let phone = AppearanceOptionEditor(surface: .phone, option: .rotation, store: store)
    global.binding(\.minorTicks).wrappedValue = .five
    #expect(phone.value.minorTicks == .five)
    #expect(store.preferences.usesGlobal(for: .phone))
    phone.binding(\.rotation).wrappedValue = .arrow
    phone.binding(\.labels).wrappedValue = .outside
    phone.binding(\.reducedMotionDial).wrappedValue = .rotatingDial
    let saved = AppearanceStore.read(from: defaults)
    #expect(saved.effective(for: .phone).rotation == .arrow)
    #expect(saved.effective(for: .phone).labels == .outside)
    #expect(saved.effective(for: .phone).reducedMotionDial == .rotatingDial)
    #expect(saved.effective(for: .phone).minorTicks == .five)
    #expect(saved.global.rotation == .dial)
    #expect(saved.usesGlobal(for: .activity))
    global.binding(\.minorTicks).wrappedValue = .eight
    #expect(phone.value.minorTicks == .five)
    store.update { $0.setUsesGlobal(true, for: .phone) }
    #expect(phone.value.minorTicks == .eight)
    #expect(phone.value.rotation == .dial)
    // A binding made before a later store update must preserve the newer fields.
    let labels = phone.binding(\.labels)
    global.binding(\.minorTicks).wrappedValue = .none
    labels.wrappedValue = .hidden
    #expect(phone.value.minorTicks == .none)
    #expect(phone.value.labels == .hidden)
    #expect(
      AppearanceStore(defaults: defaults, legacyDefaults: defaults).preferences == store.preferences
    )
  }

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

  @Test func appThemePersistsAndUpdatesTheAppAndSettingsPresentation() async throws {
    let name = "theme-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(store.preferences.theme == .system)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.overrideUserInterfaceStyle = .dark
    var observed: [String: ColorScheme] = [:]
    let host = UIHostingController(
      rootView:
        ZStack {
          ThemeProbe { observed["compass"] = $0 }
          NavigationStack {
            Form { ThemeProbe { observed["settings"] = $0 } }
          }
        }
        .modifier(AppThemeModifier(store: store)))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    for (theme, expected) in [
      (AppTheme.dark, ColorScheme.dark), (.light, .light), (.system, .dark),
    ] {
      store.update { $0.theme = theme }
      let deadline = ContinuousClock.now + .seconds(3)
      while (observed["compass"] != expected || observed["settings"] != expected),
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(observed["compass"] == expected)
      #expect(observed["settings"] == expected)
      #expect(
        AppearanceStore(defaults: defaults, legacyDefaults: defaults).preferences.theme == theme)
    }
    // System must release the override, including subsequent host appearance changes.
    window.overrideUserInterfaceStyle = .light
    let deadline = ContinuousClock.now + .seconds(3)
    while (observed["compass"] != .light || observed["settings"] != .light),
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(observed["compass"] == .light)
    #expect(observed["settings"] == .light)
  }

  @Test func everyReadoutSizeMapsToItsDynamicTypeCategoryInOrder() {
    // Choosing a larger custom size must render larger, and the accessibility boundary the
    // slider shows must be the one the system applies.
    let mapped = ReadoutTextSize.allCases.map(\.dynamicTypeSize)
    #expect(mapped == mapped.sorted())
    #expect(Set(mapped).count == mapped.count)
    #expect(ReadoutTextSize.xxxLarge.dynamicTypeSize == .xxxLarge)
    #expect(ReadoutTextSize.accessibility5.dynamicTypeSize == .accessibility5)
    #expect(
      ReadoutTextSize.allCases.allSatisfy {
        $0.isAccessibilitySize == $0.dynamicTypeSize.isAccessibilitySize
      })
    // Every slider step announces a distinct value.
    let titles = ReadoutTextSize.allCases.map(\.title)
    #expect(Set(titles).count == titles.count)
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

private struct ThemeProbe: View {
  @Environment(\.colorScheme) private var scheme
  let observed: (ColorScheme) -> Void

  var body: some View {
    Color.clear.frame(width: 1, height: 1)
      .onChange(of: scheme, initial: true) { _, value in observed(value) }
  }
}
