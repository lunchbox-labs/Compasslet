import Foundation
import Observation
import XCTest
@testable import Compass

final class CompassDiagnosticsTests: XCTestCase {
  private func makeStore(
    retainedEvents: Int = 50_000, storage: CompassDiagnostics.Storage = .init()
  ) throws -> CompassDiagnostics {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    return try CompassDiagnostics(
      directory: directory, retainedEvents: retainedEvents, storage: storage)
  }

  private func eventsFile(of store: CompassDiagnostics) -> URL {
    store.directory.appendingPathComponent("events.jsonl")
  }

  private func lineCount(of store: CompassDiagnostics) throws -> Int {
    try Data(contentsOf: eventsFile(of: store)).split(separator: 0x0A).count
  }

  private func appendLines(_ text: String, to store: CompassDiagnostics) throws {
    let handle = try FileHandle(forWritingTo: eventsFile(of: store))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  func testRetentionUsesSeparateActiveClocksAndDoesNotCountIdleGaps() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.record(.activity, kind: .updateCompleted, wall: 100, uptime: 100)
    for second in 1...1801 {
      try store.observe(
        .fullscreen, active: true, wall: Double(100 + second), uptime: Double(100 + second))
    }
    let snapshot = try store.snapshot()
    XCTAssertFalse(
      snapshot.events.contains { $0.surface == .fullscreen && $0.kind == .templateUpdated })
    XCTAssertTrue(
      snapshot.events.contains { $0.surface == .activity && $0.kind == .updateCompleted })
    // Events that aged out stay out after a relaunch, though the file still holds them.
    XCTAssertEqual(
      try CompassDiagnostics(directory: store.directory).snapshot().events, snapshot.events)
    try store.observe(.activity, active: true, wall: 100_000, uptime: 100_000)
    XCTAssertEqual(
      try store.snapshot().surfaces.first { $0.surface == .activity }?.activeSeconds, 0)
  }

  func testDisableClearsLogsAndClocksWithoutReenablingCollection() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    XCTAssertFalse(try store.snapshot().events.isEmpty)
    try store.setEnabled(false)
    XCTAssertFalse(try store.record(.fullscreen, kind: .updateRequested, wall: 101, uptime: 101))
    try store.observe(.fullscreen, active: true, wall: 102, uptime: 102)
    let cleared = try store.snapshot()
    XCTAssertTrue(cleared.events.isEmpty)
    XCTAssertTrue(cleared.surfaces.allSatisfy { $0.activeSeconds == 0 })
    let reopened = try CompassDiagnostics(directory: store.directory)
    XCTAssertFalse(reopened.isEnabled)
    XCTAssertTrue(try reopened.snapshot().events.isEmpty)
    try store.clear()
    XCTAssertFalse(store.isEnabled)
  }

  func testEnabledFlagIsObservable() throws {
    let store = try makeStore()
    let flag = ObservationFlag()
    withObservationTracking {
      _ = store.isEnabled
    } onChange: {
      flag.raise()
    }
    try store.setEnabled(true)
    XCTAssertTrue(flag.raised)
    XCTAssertTrue(store.isEnabled)
  }

  func testDelayedCompletionCannotEnterNewRecordingSessionAfterDisableOrClear() throws {
    for disable in [true, false] {
      let store = try makeStore()
      try store.setEnabled(true)
      try store.observe(.activity, active: true, wall: 100, uptime: 100)
      let oldSession = try XCTUnwrap(store.recordingSession(.activity))
      XCTAssertTrue(
        try store.record(
          .activity, kind: .updateRequested, matchingSession: oldSession, wall: 100, uptime: 100))
      if disable {
        try store.setEnabled(false)
        XCTAssertNil(try store.recordingSession(.activity))
        try store.setEnabled(true)
      } else {
        try store.clear()
        XCTAssertTrue(store.isEnabled)
      }
      try store.observe(.activity, active: true, wall: 101, uptime: 101)
      let currentSession = try XCTUnwrap(store.recordingSession(.activity))
      XCTAssertNotEqual(oldSession, currentSession)
      XCTAssertFalse(
        try store.record(
          .activity, kind: .updateCompleted, matchingSession: oldSession, wall: 101, uptime: 101))
      XCTAssertTrue(
        try store.record(
          .activity, kind: .updateCompleted, matchingSession: currentSession, wall: 101, uptime: 101
        ))
      XCTAssertTrue(try store.snapshot().events.allSatisfy { $0.session == currentSession })
    }
  }

  func testDisableSerializesWithConcurrentWriters() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    DispatchQueue.concurrentPerform(iterations: 20) { index in
      do {
        if index == 0 {
          try store.setEnabled(false)
        } else {
          try store.observe(.activity, active: true, wall: 101, uptime: 101)
          try store.record(.activity, kind: .updateCompleted, wall: 101, uptime: 101)
        }
      } catch { XCTFail("Concurrent disable/write failed: \(error)") }
    }
    XCTAssertFalse(store.isEnabled)
    XCTAssertTrue(try store.snapshot().events.isEmpty)
    XCTAssertTrue(try store.snapshot().surfaces.allSatisfy { $0.activeSeconds == 0 })
    XCTAssertTrue(try CompassDiagnostics(directory: store.directory).snapshot().events.isEmpty)
  }

  func testUnknownAndMalformedLinesAreLeftOutOfTheExport() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.record(.activity, kind: .updateCompleted, wall: 100, uptime: 100)
    let retained = try store.snapshot().events
    // A surface and a kind this version doesn't record, a line that isn't an event, and one
    // cut short by the app stopping mid-write.
    let lines = """
      {"sequence":90,"surface":"widget","kind":"reloadRequested","wall":100,"uptime":100,\
      "elapsed":0,"session":"other"}
      {"sequence":91,"surface":"activity","kind":"retiredKind","wall":100,"uptime":100,\
      "elapsed":0,"session":"other"}
      not json
      {"sequence":92,"surface":"activity","kind":"upd
      """
    try appendLines(lines, to: store)
    let reopened = try CompassDiagnostics(directory: store.directory)
    XCTAssertEqual(try reopened.snapshot().events, retained)
    XCTAssertNoThrow(try reopened.exportJSON())
    // Opening rewrote the file without them, so the cut-short line can't swallow the next event.
    XCTAssertEqual(try lineCount(of: reopened), retained.count)
    try reopened.observe(.activity, active: true, wall: 101, uptime: 101)
    XCTAssertTrue(try reopened.record(.activity, kind: .updateCompleted, wall: 101, uptime: 101))
    let events = try CompassDiagnostics(directory: store.directory).snapshot().events
    XCTAssertEqual(events.count, retained.count + 2)
    XCTAssertEqual(events.last?.kind, .updateCompleted)
  }

  func testFailedClearDoesNotPretendDebugModeWasDisabled() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    let retained = try store.snapshot().events
    // A directory the store can't write to makes erasing the log fail.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: store.directory.path)
    XCTAssertThrowsError(try store.setEnabled(false))
    XCTAssertThrowsError(try store.clear())
    XCTAssertTrue(store.isEnabled)
    XCTAssertEqual(try store.snapshot().events, retained)
    let reopened = try CompassDiagnostics(directory: store.directory)
    XCTAssertTrue(reopened.isEnabled)
    XCTAssertEqual(try reopened.snapshot().events, retained)
  }

  func testUndecodableSettingsStartOverWithDebugModeOff() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try Data("{".utf8).write(to: store.directory.appendingPathComponent("settings.json"))
    let reopened = try CompassDiagnostics(directory: store.directory)
    XCTAssertFalse(reopened.isEnabled)
    XCTAssertTrue(try reopened.snapshot().events.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: eventsFile(of: store).path))
  }

  func testFailedSettingsWriteAfterEraseKeepsMemoryMatchingTheFiles() throws {
    let faults = Faults()
    let store = try makeStore(storage: faults.storage)
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.record(.activity, kind: .updateCompleted, wall: 100, uptime: 100)
    faults.failSettings = true
    XCTAssertThrowsError(try store.setEnabled(false))
    faults.failSettings = false
    // The log is already gone, but the switch was never saved off.
    XCTAssertTrue(store.isEnabled)
    XCTAssertTrue(try store.snapshot().events.isEmpty)
    let reopened = try CompassDiagnostics(directory: store.directory)
    XCTAssertTrue(reopened.isEnabled)
    XCTAssertTrue(try reopened.snapshot().events.isEmpty)
  }

  func testFailedAppendLeavesNoFragmentBehind() throws {
    let faults = Faults()
    let store = try makeStore(storage: faults.storage)
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    faults.cutAppends = true
    XCTAssertThrowsError(
      try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100))
    faults.cutAppends = false
    XCTAssertEqual(try store.snapshot().events.map(\.kind), [.started])
    XCTAssertEqual(try Data(contentsOf: eventsFile(of: store)).last, 0x0A)
    XCTAssertEqual(try lineCount(of: store), 1)
    XCTAssertTrue(try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100))
    let events = try store.snapshot().events
    XCTAssertEqual(events.map(\.kind), [.started, .templateUpdated])
    XCTAssertEqual(Set(events.map(\.sequence)).count, 2)
    XCTAssertEqual(try CompassDiagnostics(directory: store.directory).snapshot().events, events)
  }

  func testCompactionRewritesTheFileToTheRetainedEvents() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    for _ in 0..<1100 {
      try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    }
    XCTAssertEqual(try lineCount(of: store), 1102)
    for second in 1...1801 {
      try store.observe(
        .fullscreen, active: true, wall: Double(100 + second), uptime: Double(100 + second))
    }
    let events = try store.snapshot().events
    XCTAssertEqual(events.map(\.surface), [.activity])
    XCTAssertEqual(try lineCount(of: store), events.count)
  }

  func testEachSurfaceKeepsItsNewestEventsUpToTheLimit() throws {
    let store = try makeStore(retainedEvents: 3)
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    for _ in 0..<4 {
      try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    }
    let events = try store.snapshot().events
    XCTAssertEqual(events.filter { $0.surface == .fullscreen }.map(\.sequence), [4, 5, 6])
    XCTAssertEqual(events.filter { $0.surface == .activity }.map(\.sequence), [1])
    let reopened = try CompassDiagnostics(directory: store.directory, retainedEvents: 3)
    XCTAssertEqual(try reopened.snapshot().events, events)
  }

  func testLegacyAppGroupStoreIsRemoved() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: container) }
    let legacy = container.appendingPathComponent("Diagnostics", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    for name in ["timing.sqlite", "timing.sqlite-wal", "timing.sqlite-shm"] {
      try Data("events".utf8).write(to: legacy.appendingPathComponent(name))
    }
    let other = container.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    CompassDiagnostics.removeLegacyStore(in: container)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    CompassDiagnostics.removeLegacyStore(in: container)
    CompassDiagnostics.removeLegacyStore(in: nil)
  }

  func testPauseResumeAndRestartExcludeIdleTimeFromIntervals() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    try store.observe(.fullscreen, active: true, wall: 101, uptime: 101)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 101, uptime: 101)
    try store.observe(.fullscreen, active: false, wall: 102, uptime: 102)
    try store.observe(.fullscreen, active: true, wall: 10_000, uptime: 10_000)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 10_000, uptime: 10_000)
    let restarted = try CompassDiagnostics(directory: store.directory)
    try restarted.observe(.fullscreen, active: true, wall: 10_001, uptime: 10_001)
    let summary = try XCTUnwrap(restarted.snapshot().surfaces.first { $0.surface == .fullscreen })
    XCTAssertEqual(summary.activeSeconds, 2)
    XCTAssertEqual(summary.intervals.first { $0.kind == .templateUpdated }?.meanIntervalSeconds, 1)
    XCTAssertEqual(Set(try restarted.snapshot().events.map(\.sequence)).count, 7)
    try restarted.clear()
    XCTAssertTrue(restarted.isEnabled)
    try restarted.observe(.fullscreen, active: true, wall: 10_002, uptime: 10_002)
    XCTAssertEqual(
      try restarted.snapshot().surfaces.first { $0.surface == .fullscreen }?.activeSeconds, 0)
  }

  func testExportContainsElapsedIntervalsWithoutRawBootUptime() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 987654)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 987654)
    try store.observe(.fullscreen, active: true, wall: 101, uptime: 987655)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 101, uptime: 987655)
    let data = try store.exportJSON()
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("987654"))
    XCTAssertFalse(text.contains("987655"))
    let snapshot = try JSONDecoder().decode(CompassDiagnostics.Snapshot.self, from: data)
    XCTAssertEqual(
      snapshot.events.filter { $0.kind == .templateUpdated }.map(\.elapsedSinceFirstRetainedEvent),
      [0, 1])
    XCTAssertEqual(
      snapshot.surfaces.first { $0.surface == .fullscreen }?.intervals.first {
        $0.kind == .templateUpdated
      }?.meanIntervalSeconds, 1)
  }

  func testConcurrentWritersExportConsistentEventsAndIntervals() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    DispatchQueue.concurrentPerform(iterations: 20) { _ in
      do {
        try store.record(.fullscreen, kind: .updateRequested, wall: 100, uptime: 100)
        let snapshot = try JSONDecoder().decode(
          CompassDiagnostics.Snapshot.self, from: store.exportJSON())
        let summarized = snapshot.surfaces.flatMap(\.intervals).reduce(0) { $0 + $1.count }
        XCTAssertEqual(summarized, snapshot.events.count)
        XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, snapshot.events.count)
        try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
      } catch { XCTFail("Concurrent write failed: \(error)") }
    }
    let data = try store.exportJSON()
    let snapshot = try JSONDecoder().decode(CompassDiagnostics.Snapshot.self, from: data)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .updateRequested }.count, 20)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .templateUpdated }.count, 20)
    XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, snapshot.events.count)
    XCTAssertEqual(
      try CompassDiagnostics(directory: store.directory).snapshot().events, snapshot.events)
    try store.observe(.fullscreen, active: false, wall: 101, uptime: 101)
    let count = try store.snapshot().events.count
    try store.record(.fullscreen, kind: .updateRequested, wall: 102, uptime: 102)
    XCTAssertEqual(try store.snapshot().events.count, count)
  }
}

/// Makes the store's settings writes fail, or its appends stop half-way, while set.
private final class Faults: @unchecked Sendable {
  var failSettings = false
  var cutAppends = false

  var storage: CompassDiagnostics.Storage {
    let real = CompassDiagnostics.Storage()
    var storage = real
    storage.replace = { data, url in
      if self.failSettings, url.lastPathComponent == "settings.json" {
        throw CocoaError(.fileWriteUnknown)
      }
      try real.replace(data, url)
    }
    storage.write = { handle, data in
      guard self.cutAppends else { return try real.write(handle, data) }
      try real.write(handle, data.prefix(data.count / 2))
      throw CocoaError(.fileWriteUnknown)
    }
    return storage
  }
}
