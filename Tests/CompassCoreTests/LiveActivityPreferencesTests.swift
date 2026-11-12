import CompassCore
import Foundation
import Testing

@Test func liveActivityPreferencesStartAsTheBehaviourBeforeTheSettings() {
  let standard = LiveActivityPreferences()
  #expect(standard.refreshRate == .everySecond)
  #expect(standard.refreshRate.interval == 1)
  #expect(standard.autoStop == .afterOneMinute)
  #expect(standard.autoStop.delay == 60)
  // Nothing saved yet, as for everyone before the settings existed.
  #expect(LiveActivityPreferences.decode(nil) == standard)
}

@Test func liveActivityChoicesGiveTheirIntervalsAndDelays() {
  #expect(LiveActivityRefreshRate.allCases.map(\.interval) == [1, 5, 15, 30])
  #expect(LiveActivityAutoStop.allCases.map(\.delay) == [60, 300, 900, nil])
}

@Test func liveActivityPreferencesRoundTripAndRecoverFromBadStorage() throws {
  var chosen = LiveActivityPreferences()
  chosen.refreshRate = .everyFifteenSeconds
  chosen.autoStop = .never
  let data = try JSONEncoder().encode(chosen)
  #expect(LiveActivityPreferences.decode(data) == chosen)
  // The stored form keeps its raw values, so saved choices keep their meaning.
  let stored = try JSONDecoder().decode([String: Int].self, from: data)
  #expect(stored == ["refreshRate": 15, "autoStop": 0])
  // A missing key, or a value this version doesn't know, keeps the standard choice for it alone.
  #expect(
    LiveActivityPreferences.decode(Data(#"{"autoStop":300}"#.utf8)).refreshRate == .everySecond)
  let unknown = LiveActivityPreferences.decode(Data(#"{"refreshRate":2,"autoStop":300}"#.utf8))
  #expect(unknown.refreshRate == .everySecond)
  #expect(unknown.autoStop == .afterFiveMinutes)
  #expect(LiveActivityPreferences.decode(Data("not json".utf8)) == LiveActivityPreferences())
  #expect(LiveActivityPreferences.decode(Data("[]".utf8)) == LiveActivityPreferences())
}
