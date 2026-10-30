import Foundation
import XCTest
@testable import Compass

final class CompassDiagnosticsTests: XCTestCase {
  private func makeStore() throws -> CompassDiagnostics {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    return try CompassDiagnostics(url: url)
  }

  func testRetentionUsesSeparateActiveClocksAndDoesNotCountIdleGaps() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.widget, active: true, wall: 100, uptime: 100)
    try store.record(.widget, kind: .reloadRequested, wall: 100, uptime: 100)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.record(.activity, kind: .updateCompleted, wall: 100, uptime: 100)
    for second in 1...1801 {
      try store.observe(
        .widget, active: true, wall: Double(100 + second), uptime: Double(100 + second))
    }
    let snapshot = try store.snapshot()
    XCTAssertFalse(
      snapshot.events.contains { $0.surface == .widget && $0.kind == .reloadRequested })
    XCTAssertTrue(
      snapshot.events.contains { $0.surface == .activity && $0.kind == .updateCompleted })
    try store.observe(.activity, active: true, wall: 100_000, uptime: 100_000)
    XCTAssertEqual(
      try store.snapshot().surfaces.first { $0.surface == .activity }?.activeSeconds, 0)
  }

  func testDisableRetainsLogsAndClearDoesNotReenableCollection() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.widget, active: true, wall: 100, uptime: 100)
    try store.record(.widget, kind: .reloadRequested, wall: 100, uptime: 100)
    try store.setEnabled(false)
    let retained = try store.snapshot().events
    try store.record(.widget, kind: .providerCreated, wall: 101, uptime: 101)
    XCTAssertEqual(try store.snapshot().events, retained)
    try store.clear()
    try store.observe(.widget, active: true, wall: 102, uptime: 102)
    XCTAssertTrue(try store.snapshot().events.isEmpty)
    XCTAssertFalse(try store.isEnabled())
  }

  func testPauseResumeAndRestartExcludeIdleTimeFromIntervals() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.widget, active: true, wall: 100, uptime: 100)
    try store.record(.widget, kind: .reloadRequested, wall: 100, uptime: 100)
    try store.observe(.widget, active: true, wall: 101, uptime: 101)
    try store.record(.widget, kind: .reloadRequested, wall: 101, uptime: 101)
    try store.observe(.widget, active: false, wall: 102, uptime: 102)
    try store.observe(.widget, active: true, wall: 10_000, uptime: 10_000)
    try store.record(.widget, kind: .reloadRequested, wall: 10_000, uptime: 10_000)
    let restarted = try CompassDiagnostics(url: store.url)
    try restarted.observe(.widget, active: true, wall: 10_001, uptime: 10_001)
    let summary = try XCTUnwrap(restarted.snapshot().surfaces.first { $0.surface == .widget })
    XCTAssertEqual(summary.activeSeconds, 2)
    XCTAssertEqual(summary.intervals.first { $0.kind == .reloadRequested }?.meanIntervalSeconds, 1)
    try restarted.clear()
    XCTAssertTrue(try restarted.isEnabled())
    try restarted.observe(.widget, active: true, wall: 10_002, uptime: 10_002)
    XCTAssertEqual(
      try restarted.snapshot().surfaces.first { $0.surface == .widget }?.activeSeconds, 0)
  }

  func testExportContainsElapsedIntervalsWithoutRawBootUptime() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.widget, active: true, wall: 100, uptime: 987654)
    try store.record(.widget, kind: .reloadRequested, wall: 100, uptime: 987654)
    try store.observe(.widget, active: true, wall: 101, uptime: 987655)
    try store.record(.widget, kind: .reloadRequested, wall: 101, uptime: 987655)
    let data = try store.exportJSON()
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("987654"))
    XCTAssertFalse(text.contains("987655"))
    let snapshot = try JSONDecoder().decode(CompassDiagnostics.Snapshot.self, from: data)
    XCTAssertEqual(
      snapshot.events.filter { $0.kind == .reloadRequested }.map(\.elapsedSinceFirstRetainedEvent),
      [0, 1])
    XCTAssertEqual(
      snapshot.surfaces.first { $0.surface == .widget }?.intervals.first {
        $0.kind == .reloadRequested
      }?.meanIntervalSeconds, 1)
  }

  func testConcurrentConnectionsExportConsistentEventsAndIntervals() throws {
    let store = try makeStore()
    let provider = try CompassDiagnostics(url: store.url)
    try store.setEnabled(true)
    try store.observe(.widget, active: true, wall: 100, uptime: 100)
    DispatchQueue.concurrentPerform(iterations: 20) { _ in
      do {
        try provider.record(.widget, kind: .providerCreated, wall: 100, uptime: 100)
        let snapshot = try JSONDecoder().decode(
          CompassDiagnostics.Snapshot.self, from: store.exportJSON())
        let summarized = snapshot.surfaces.flatMap(\.intervals).reduce(0) { $0 + $1.count }
        XCTAssertEqual(summarized, snapshot.events.count)
        XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, snapshot.events.count)
        try store.record(.widget, kind: .reloadRequested, wall: 100, uptime: 100)
      } catch { XCTFail("Concurrent write failed: \(error)") }
    }
    let data = try store.exportJSON()
    let snapshot = try JSONDecoder().decode(CompassDiagnostics.Snapshot.self, from: data)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .providerCreated }.count, 20)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .reloadRequested }.count, 20)
    XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, snapshot.events.count)
    try store.observe(.widget, active: false, wall: 101, uptime: 101)
    let count = try store.snapshot().events.count
    try provider.record(.widget, kind: .providerCreated, wall: 102, uptime: 102)
    XCTAssertEqual(try store.snapshot().events.count, count)
  }
}
