import Foundation
import Testing
@testable import Compass

/// How a surface's calls make up its sessions, with the clock injected as each call's times.
@Suite
struct CompassDiagnosticsSessionTests {
  /// A repeat under 1 s after the call written isn't written, so a beat that wakes late after it
  /// lands over 2 s after the last call written, though under 2 s after the repeat.
  @Test(arguments: CompassDiagnostics.Surface.allCases)
  func aLateCallAfterARepeatKeepsTheSession(_ surface: CompassDiagnostics.Surface) throws {
    let store = try Store()
    try store.diagnostics.setEnabled(true)
    try store.observe(surface, active: true, at: 101.25)
    let saves = store.settingsSaves
    try store.observe(surface, active: true, at: 102)
    #expect(store.settingsSaves == saves)
    try store.observe(surface, active: true, at: 103.5)
    try store.observe(surface, active: true, at: 104.5)
    try store.observe(surface, active: true, at: 105.5)
    try store.observe(surface, active: false, at: 106)
    let snapshot = try store.diagnostics.snapshot()
    let events = snapshot.events.filter { $0.surface == surface }
    #expect(events.map(\.kind) == [.started, .paused])
    #expect(events.map(\.activeSeconds) == [0, 4.75])
    #expect(Set(events.map(\.session)).count == 1)
    #expect(snapshot.surfaces.first { $0.surface == surface }?.activeSeconds == 4.75)
  }

  @Test func aGapOverTwoSecondsAfterARepeatStartsANewSession() throws {
    let store = try Store()
    try store.diagnostics.setEnabled(true)
    try store.observe(.activity, active: true, at: 100)
    try store.observe(.activity, active: true, at: 100.5)
    try store.observe(.activity, active: true, at: 102.75)
    let events = try store.diagnostics.snapshot().events
    #expect(events.map(\.kind) == [.started, .started])
    #expect(events.map(\.activeSeconds) == [0, 0])
    #expect(Set(events.map(\.session)).count == 2)
  }

  /// A failed write leaves the clock at the call before it, so repeats of the failed call can't
  /// bridge the gap from that earlier call.
  @Test func repeatsOfACallThatWasNotWrittenDoNotKeepTheSession() throws {
    let store = try Store()
    try store.diagnostics.setEnabled(true)
    try store.observe(.activity, active: true, at: 100)
    store.failSettingsSaves = true
    #expect(throws: CompassDiagnostics.Failure.self) {
      try store.observe(.activity, active: true, at: 103)
    }
    store.failSettingsSaves = false
    try store.observe(.activity, active: true, at: 103.5)
    try store.observe(.activity, active: true, at: 104.25)
    let events = try store.diagnostics.snapshot().events
    #expect(events.map(\.kind) == [.started, .started])
    #expect(events.map(\.activeSeconds) == [0, 0])
  }

  @Test func eventsRecordUntilTwoSecondsAfterTheLastCallSeen() throws {
    let store = try Store()
    try store.diagnostics.setEnabled(true)
    try store.observe(.activity, active: true, at: 100)
    try store.observe(.activity, active: true, at: 100.75)
    #expect(try store.record(.activity, at: 99.5) == false)
    #expect(try store.record(.activity, at: 102.5))
    #expect(try store.record(.activity, at: 103) == false)
  }
}

/// A store in a temporary folder that counts its settings saves and can make them fail.
private final class Store {
  let diagnostics: CompassDiagnostics
  private let directory: URL
  private let settings: SettingsWrites

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let settings = SettingsWrites()
    self.settings = settings
    let real = CompassDiagnostics.Storage()
    var storage = real
    storage.replace = { data, url in
      if url.lastPathComponent == "settings.json" {
        guard !settings.fail else { throw CocoaError(.fileWriteUnknown) }
        settings.saves += 1
      }
      try real.replace(data, url)
    }
    diagnostics = try CompassDiagnostics(directory: directory, storage: storage)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  var settingsSaves: Int { settings.saves }

  var failSettingsSaves: Bool {
    get { settings.fail }
    set { settings.fail = newValue }
  }

  func observe(_ surface: CompassDiagnostics.Surface, active: Bool, at seconds: Double) throws {
    try diagnostics.observe(surface, active: active, wall: seconds, uptime: seconds)
  }

  func record(_ surface: CompassDiagnostics.Surface, at seconds: Double) throws -> Bool {
    try diagnostics.record(surface, kind: .updateCompleted, wall: seconds, uptime: seconds)
  }
}

/// The settings saves a store has made, and whether the next ones fail. A test changes it only
/// between its store's calls.
private final class SettingsWrites: @unchecked Sendable {
  var saves = 0
  var fail = false
}
