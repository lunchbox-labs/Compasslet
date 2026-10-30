import CompassCore
import Foundation
import Testing

@Test func appearanceOverridesCopyCurrentGlobalsAndDiscardOldCustomizations() {
  var preferences = AppearancePreferences()
  var global = preferences.global
  global.showDegrees = false
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .phone).showDegrees == false)
  preferences.setUsesGlobal(false, for: .phone)
  var phone = preferences.effective(for: .phone)
  phone.rotation = .arrow
  preferences.setOverride(phone, for: .phone)
  global.showDegrees = true
  global.labels = .outside
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .phone).labels != .outside)
  #expect(preferences.effective(for: .activity).labels == .outside)
  preferences.setUsesGlobal(true, for: .phone)
  #expect(preferences.effective(for: .phone) == preferences.global)
  preferences.setUsesGlobal(false, for: .phone)
  #expect(preferences.effective(for: .phone) == preferences.global)
}

@Test func dialOverridesCanHideBothButGlobalAndActivityKeepAReading() {
  var preferences = AppearancePreferences()
  var hidden = preferences.global
  hidden.showDirection = false
  hidden.showDegrees = false
  preferences.setGlobal(hidden)
  #expect(preferences.global.showDirection)
  preferences.setOverride(hidden, for: .phone)
  #expect(!preferences.effective(for: .phone).hasReadout)
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
  #expect(preferences.effective(for: .activity).useSystemTextSize)
  #expect(!preferences.effective(for: .phone).useSystemTextSize)
  #expect(preferences.effective(for: .phone).customTextSize == .xxxLarge)
  preferences.setUsesGlobal(true, for: .phone)
  #expect(preferences.effective(for: .phone).useSystemTextSize)
  let restored = AppearancePreferences.decode(try JSONEncoder().encode(preferences))
  #expect(restored == preferences)
}

@Test func retiredWidgetPreferencesDoNotResetOtherSurfacesOrRemainInSettings() throws {
  var preferences = AppearancePreferences()
  var phone = preferences.global
  phone.rotation = .arrow
  preferences.setOverride(phone, for: .phone)
  var activity = preferences.global
  activity.showDegrees = false
  preferences.setOverride(activity, for: .activity)
  let encoded = try JSONEncoder().encode(preferences)
  var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  legacy["widget"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(phone))
  let decoded = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: legacy))
  #expect(decoded.effective(for: .phone) == phone)
  #expect(decoded.effective(for: .activity) == activity)
  #expect(AppearanceSurface.allCases.map(\.rawValue) == ["phone", "activity"])
  let saved = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
  #expect(saved["widget"] == nil)
}
