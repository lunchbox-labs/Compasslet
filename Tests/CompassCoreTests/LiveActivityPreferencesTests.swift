import CompassCore
import Foundation
import Testing

@Test func liveActivityPreferencesStartAsTheBehaviourBeforeTheSettings() {
  let standard = LiveActivityPreferences()
  #expect(standard.updateFrequency == .everySecond)
  #expect(standard.updateFrequency.interval == 1)
  #expect(standard.autoStop == .oneMinute)
  #expect(standard.autoStop.delay == 60)
  // Nothing saved yet, as for everyone before the settings existed.
  #expect(LiveActivityPreferences.decode(nil) == standard)
}

@Test func liveActivityChoicesGiveTheirIntervalsAndDelays() {
  #expect(LiveActivityUpdateFrequency.allCases.map(\.interval) == [1, 5, 15])
  #expect(LiveActivityAutoStop.allCases.map(\.delay) == [60, 300, 900, nil])
}

@Test func liveActivityPreferencesRoundTripAndRecoverFromBadStorage() throws {
  var chosen = LiveActivityPreferences()
  chosen.updateFrequency = .everyFifteenSeconds
  chosen.autoStop = .never
  let data = try JSONEncoder().encode(chosen)
  #expect(LiveActivityPreferences.decode(data) == chosen)
  // The stored form keeps its raw values, so saved choices keep their meaning.
  let stored = try JSONDecoder().decode([String: Int].self, from: data)
  #expect(stored == ["refreshRate": 15, "autoStop": 0])
  // A missing key, or a value this version doesn't know, keeps the standard choice for it alone.
  #expect(
    LiveActivityPreferences.decode(Data(#"{"autoStop":300}"#.utf8)).updateFrequency == .everySecond)
  let unknown = LiveActivityPreferences.decode(Data(#"{"refreshRate":2,"autoStop":300}"#.utf8))
  #expect(unknown.updateFrequency == .everySecond)
  #expect(unknown.autoStop == .fiveMinutes)
  #expect(LiveActivityPreferences.decode(Data("not json".utf8)) == LiveActivityPreferences())
  #expect(LiveActivityPreferences.decode(Data("[]".utf8)) == LiveActivityPreferences())
}

@Test func liveActivityPreferencesReadAWithdrawnUpdateFrequencyAsTheDefault() {
  // Early test builds offered 30 seconds and saved it under the same key.
  let saved = LiveActivityPreferences.decode(Data(#"{"refreshRate":30,"autoStop":900}"#.utf8))
  #expect(saved.updateFrequency == .everySecond)
  #expect(saved.autoStop == .fifteenMinutes)
  // The choices still offered keep their meaning.
  let kept = LiveActivityPreferences.decode(Data(#"{"refreshRate":15,"autoStop":0}"#.utf8))
  #expect(kept.updateFrequency == .everyFifteenSeconds)
  #expect(kept.autoStop == .never)
}
