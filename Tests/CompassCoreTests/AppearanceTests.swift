import CompassCore
import Foundation
import Testing

@Test func appearanceOverridesCopyCurrentGlobalsAndDiscardOldCustomizations() {
  var preferences = AppearancePreferences()
  var global = preferences.global
  global.showDegrees = false
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .widget).showDegrees == false)
  preferences.setUsesGlobal(false, for: .widget)
  var widget = preferences.effective(for: .widget)
  widget.rotation = .arrow
  preferences.setOverride(widget, for: .widget)
  global.showDegrees = true
  global.labels = .outside
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .widget).labels != .outside)
  #expect(preferences.effective(for: .phone).labels == .outside)
  preferences.setUsesGlobal(true, for: .widget)
  #expect(preferences.effective(for: .widget) == preferences.global)
  preferences.setUsesGlobal(false, for: .widget)
  #expect(preferences.effective(for: .widget) == preferences.global)
}

@Test func dialOverridesCanHideBothButGlobalAndActivityKeepAReading() {
  var preferences = AppearancePreferences()
  var hidden = preferences.global
  hidden.showDirection = false
  hidden.showDegrees = false
  preferences.setGlobal(hidden)
  #expect(preferences.global.showDirection)
  for surface in [AppearanceSurface.phone, .widget] {
    preferences.setOverride(hidden, for: surface)
    #expect(!preferences.effective(for: surface).hasReadout)
  }
  preferences.setOverride(hidden, for: .activity)
  #expect(preferences.effective(for: .activity).showDirection)
  #expect(!preferences.effective(for: .activity).showDegrees)
}

@Test func appearanceRoundTripAndMalformedStorageRecovery() throws {
  var preferences = AppearancePreferences()
  var custom = preferences.global
  custom.labels = .hidden
  custom.minorTicks = .eight
  preferences.setOverride(custom, for: .phone)
  let data = try JSONEncoder().encode(preferences)
  #expect(AppearancePreferences.decode(data) == preferences)
  #expect(AppearancePreferences.decode(Data("bad json".utf8)).effective(for: .activity).hasReadout)
  let invalid = Data("{\"global\":{\"showDirection\":false,\"showDegrees\":false}}".utf8)
  #expect(AppearancePreferences.decode(invalid).effective(for: .activity).hasReadout)
}

@Test func tickChoicesDivideEveryQuadrantWithoutDuplicatedEndpoints() {
  for choice in MinorTicks.allCases {
    let angles = choice.angles
    #expect(angles.count == 4 * (choice.rawValue + 1))
    #expect(Set(angles).count == angles.count)
    #expect(angles.filter { $0.truncatingRemainder(dividingBy: 90) == 0 } == [0, 90, 180, 270])
    #expect(angles.allSatisfy { (0..<360).contains($0) })
  }
}

@Test func readoutSizeChoiceFollowsGlobalsUntilSurfaceOverrides() throws {
  var preferences = AppearancePreferences()
  var global = preferences.global
  global.useSystemTextSize = false
  global.customTextSize = .xxxLarge
  preferences.setGlobal(global)
  preferences.setUsesGlobal(false, for: .phone)
  global.useSystemTextSize = true
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .widget).useSystemTextSize)
  #expect(!preferences.effective(for: .phone).useSystemTextSize)
  #expect(preferences.effective(for: .phone).customTextSize == .xxxLarge)
  preferences.setUsesGlobal(true, for: .phone)
  #expect(preferences.effective(for: .phone).useSystemTextSize)
  let restored = AppearancePreferences.decode(try JSONEncoder().encode(preferences))
  #expect(restored == preferences)
}
