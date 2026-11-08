import Foundation
import Observation
import XCTest
@testable import Compass

final class CompassDiagnosticsTests: XCTestCase {
  private func makeStore() throws -> CompassDiagnostics {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    return try CompassDiagnostics(directory: directory)
  }

  private func appendLines(_ text: String, to store: CompassDiagnostics) throws {
    let url = store.directory.appendingPathComponent("events.jsonl")
    let handle = try FileHandle(forWritingTo: url)
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
    // The cut-short line doesn't swallow the next event, which numbers after the unknown ones.
    try reopened.observe(.activity, active: true, wall: 101, uptime: 101)
    XCTAssertTrue(try reopened.record(.activity, kind: .updateCompleted, wall: 101, uptime: 101))
    let events = try CompassDiagnostics(directory: store.directory).snapshot().events
    XCTAssertEqual(events.count, retained.count + 2)
    XCTAssertEqual(events.last?.kind, .updateCompleted)
    XCTAssertGreaterThan(events.last?.sequence ?? 0, 91)
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

  func testUnreadableSettingsLeaveTheStoreUnopened() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try Data("{".utf8).write(to: store.directory.appendingPathComponent("settings.json"))
    XCTAssertThrowsError(try CompassDiagnostics(directory: store.directory))
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
