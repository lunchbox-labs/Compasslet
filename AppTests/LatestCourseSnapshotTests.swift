import Foundation
import XCTest
@testable import Compass

final class LatestCourseSnapshotTests: XCTestCase {
  private let time = Date(timeIntervalSince1970: 1_000)

  private func store() throws -> LatestCourseStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return LatestCourseStore(url: directory.appendingPathComponent("latest.json"))
  }

  func testReplacementExpiryAndInvalidation() throws {
    let store = try store()
    try store.write(.init(bearing: 90, status: .usable, sampleTime: time), now: time)
    XCTAssertEqual(store.read(now: time + 5).bearing, 90)
    XCTAssertEqual(store.read(now: time + 5.001).bearing, 90)
    XCTAssertEqual(store.read(now: time + 120).bearing, 90)
    XCTAssertNil(store.read(now: time + 120.001).bearing)
    try store.write(.init(bearing: 359, status: .usable, sampleTime: time + 1), now: time + 1)
    XCTAssertEqual(store.read(now: time + 1).bearing, 359)
    try store.write(.unavailable(at: time + 2), now: time + 2)
    XCTAssertNil(store.read(now: time + 2).bearing)
    XCTAssertEqual(store.read(now: time + 2).status, .unavailable)
  }

  func testDelayedProviderAndRepeatedWritesKeepOriginalSampleAge() throws {
    let store = try store()
    try store.write(.init(bearing: 90, status: .usable, sampleTime: time), now: time)
    let captured = store.read(now: time)
    XCTAssertEqual(store.read(now: time + 60).bearing, 90)
    for second in 1...120 {
      let date = time + Double(second)
      try store.write(.init(bearing: 180, status: .usable, sampleTime: date), now: date)
    }
    XCTAssertEqual(captured.validated(at: time + 60).bearing, 90)
    XCTAssertEqual(captured.validated(at: time + 60).sampleTime, time)
    XCTAssertNil(captured.validated(at: time + 121).bearing)
    XCTAssertEqual(store.read(now: time + 121).bearing, 180)
    try store.write(.unavailable(at: time + 121), now: time + 121)
    XCTAssertNil(store.read(now: time + 121).bearing)
  }

  func testFreshnessTransitionsAndLegacySnapshotCompatibility() throws {
    let store = try store()
    let legacy = LatestCourseSnapshot(bearing: 90, status: .usable, sampleTime: time)
    try JSONEncoder().encode(legacy).write(to: store.url)
    XCTAssertEqual(store.read(now: time + 5).status, .usable)
    XCTAssertEqual(store.read(now: time + 5.001).status, .historical)
    XCTAssertEqual(store.read(now: time + 120).status, .historical)
    XCTAssertEqual(store.read(now: time + 120.001).status, .unavailable)
    // Age moves live in the widget, so only retention expiry needs a scheduled entry.
    XCTAssertEqual(legacy.transitionDates(after: time), [time + 120.001])
    XCTAssertEqual(legacy.transitionDates(after: time + 60), [time + 120.001])
    XCTAssertTrue(legacy.transitionDates(after: time + 121).isEmpty)
    let slow = LatestCourseSnapshot(bearing: nil, status: .slow, sampleTime: time)
    XCTAssertEqual(slow.transitionDates(after: time), [time + 5.001])
    let historical = store.read(now: time + 60)
    try store.write(historical, now: time + 90)
    XCTAssertEqual(store.read(now: time + 100).sampleTime, time)
    try store.write(.init(bearing: 180, status: .usable, sampleTime: time + 100), now: time + 100)
    XCTAssertEqual(store.read(now: time + 100).status, .usable)
    XCTAssertEqual(store.read(now: time + 100).bearing, 180)
  }

  func testScheduledHistoricalEntryCannotBecomeFreshDuringEarlyRendering() {
    let fresh = LatestCourseSnapshot(bearing: 90, status: .usable, sampleTime: time)
    let scheduled = fresh.validated(at: time + 5.001)
    XCTAssertEqual(scheduled.status, .historical)
    XCTAssertEqual(scheduled.validated(at: time + 1).status, .historical)
    XCTAssertEqual(scheduled.sampleTime, time)
  }

  func testReadReportsMissingCorruptAndExpiredSampleWithoutHidingItsAge() throws {
    let store = try store()
    var outcome: LatestCourseStore.ReadOutcome?
    var observed: LatestCourseSnapshot?
    let report: (LatestCourseStore.ReadOutcome, LatestCourseSnapshot) -> Void = {
      outcome = $0; observed = $1
    }
    _ = store.read(now: time, report: report)
    XCTAssertEqual(outcome, .missing)
    try Data("broken".utf8).write(to: store.url)
    _ = store.read(now: time, report: report)
    XCTAssertEqual(outcome, .corrupt)
    try store.write(.init(bearing: 90, status: .usable, sampleTime: time), now: time)
    XCTAssertNil(store.read(now: time + 121, report: report).bearing)
    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(observed?.sampleTime, time)
  }

  func testRejectsFutureCorruptAndIncompatibleReadings() throws {
    let store = try store()
    for bearing in [-1.0, 360, .infinity, .nan] {
      try store.write(.init(bearing: bearing, status: .usable, sampleTime: time), now: time)
      XCTAssertNil(store.read(now: time).bearing)
    }
    try store.write(.init(bearing: 90, status: .usable, sampleTime: time), now: time)
    XCTAssertNil(store.read(now: time - 0.001).bearing)
    let data = try Data(contentsOf: store.url)
    let incompatible = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "vehicleCourseTrueNorth", with: "deviceHeadingMagnetic")
    try Data(incompatible.utf8).write(to: store.url, options: .atomic)
    XCTAssertNil(store.read(now: time).bearing)
    try Data("broken".utf8).write(to: store.url, options: .atomic)
    XCTAssertNil(store.read(now: time).bearing)
    try FileManager.default.removeItem(at: store.url)
    XCTAssertNil(store.read(now: time).bearing)
  }

  func testUnavailableStatesNeverRetainABearing() throws {
    let store = try store()
    for status in [LatestCourseSnapshot.Status.waiting, .slow, .unreliable, .unavailable] {
      try store.write(.init(bearing: 90, status: status, sampleTime: time), now: time)
      let value = store.read(now: time)
      XCTAssertEqual(value.status, status)
      XCTAssertNil(value.bearing)
      XCTAssertEqual(store.read(now: time + 6).status, .unavailable)
    }
  }

  func testReadersSeeCompleteSnapshotsDuringReplacement() throws {
    let store = try store()
    let now = time
    try store.write(.init(bearing: 90, status: .usable, sampleTime: now), now: now)
    let writing = DispatchGroup()
    writing.enter()
    DispatchQueue.global().async {
      defer { writing.leave() }
      do {
        for index in 0..<100 {
          try store.write(
            .init(bearing: index.isMultiple(of: 2) ? 90 : 180, status: .usable, sampleTime: now),
            now: now)
        }
      } catch { XCTFail("Snapshot replacement failed: \(error)") }
    }
    for _ in 0..<100 {
      let bearing = store.read(now: now).bearing
      XCTAssertTrue(bearing == 90 || bearing == 180)
    }
    writing.wait()
  }
}
