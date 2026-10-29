import CompassCore
import XCTest
@testable import Compass

@MainActor
final class CarPlayPresentationTests: XCTestCase {
  func testInvalidStatesNeverExposeBearing() {
    let now = Date()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: now)
    for status: TravelStatus in [.waiting, .slow, .unreliable, .unavailable] {
      let value = CarPlayPresentation(
        presentation: .init(sample: sample, status: status),
        setup: .ready, driving: true, compact: .active, now: now)
      XCTAssertEqual(value.bearing, "—")
    }
    let stale = CarPlayPresentation(
      presentation: .init(sample: sample, status: .usable),
      setup: .ready, driving: true, compact: .active, now: now.addingTimeInterval(6))
    XCTAssertEqual(stale.bearing, "—")
    let setup = CarPlayPresentation(
      presentation: .init(sample: sample, status: .usable),
      setup: .permissionRequired, driving: false, compact: .inactive, now: now)
    XCTAssertEqual(setup.bearing, "—")
    XCTAssertTrue(setup.status.contains("parked"))
  }

  func testTrueNorthCourseRoundingAndCompactFailure() {
    let now = Date()
    let sample = CompassSample(
      degrees: 359.8, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: now)
    let value = CarPlayPresentation(
      presentation: .init(sample: sample, status: .usable),
      setup: .ready, driving: true, compact: .unavailable, now: now)
    XCTAssertEqual(value.bearing, "0° N")
    XCTAssertEqual(value.reference, "Travel · True north")
    XCTAssertTrue(value.compact.contains("unavailable"))
    XCTAssertTrue(value.canEndDrive)
  }

  func testWrongSourceFutureTimeAndNonfiniteInputNeverExposeBearing() {
    let now = Date()
    for sample in [
      CompassSample(
        degrees: 90, source: .deviceHeading, reference: .magnetic,
        accuracy: 1, timestamp: now),
      CompassSample(
        degrees: 90, source: .vehicleCourse, reference: .trueNorth,
        accuracy: 1, timestamp: now.addingTimeInterval(1)),
      CompassSample(
        degrees: .infinity, source: .vehicleCourse, reference: .trueNorth,
        accuracy: 1, timestamp: now),
    ] {
      let value = CarPlayPresentation(
        presentation: .init(sample: sample, status: .usable),
        setup: .ready, driving: true, compact: .active, now: now)
      XCTAssertEqual(value.bearing, "—")
    }
  }

  func testLifecycleEventsDoNotWaitForActivation() async {
    var events: [String] = []
    var continuation: CheckedContinuation<Void, Never>?
    let bridge = CarPlayLifecycleBridge(
      activate: {
        events.append("active")
        await withCheckedContinuation { continuation = $0 }
      },
      resign: { events.append("resign") }, disconnect: { events.append("disconnect") },
      end: { events.append("end") })
    bridge.activate()
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    XCTAssertNotNil(continuation)
    bridge.resign()
    XCTAssertEqual(events, ["active", "resign"])
    bridge.disconnect()
    bridge.end()
    for _ in 0..<100 where !events.contains("end") || !events.contains("disconnect") {
      await Task.yield()
    }
    XCTAssertTrue(events.contains("disconnect"))
    XCTAssertTrue(events.contains("end"))
    continuation?.resume()
  }
  func testRealBridgeRetainsDriveOnResignButDisconnectStopsDuringActivityStart() async {
    let sensor = DriveSessionControllerTests.Sensor()
    let activity = DriveSessionControllerTests.Activity()
    activity.pauseStart = true
    let drive = DriveSessionController(sensor: sensor, activity: activity, automaticTick: false)
    let bridge = CarPlayLifecycleBridge(drive: drive)
    bridge.activate()
    for _ in 0..<100 where activity.startContinuation == nil { await Task.yield() }
    XCTAssertNotNil(activity.startContinuation)
    XCTAssertTrue(drive.isDriving)
    bridge.resign()
    XCTAssertTrue(drive.isDriving)
    bridge.disconnect()
    for _ in 0..<100 where drive.isDriving { await Task.yield() }
    XCTAssertFalse(drive.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    activity.startContinuation?.resume()
    await drive.waitForPendingOperations()
    XCTAssertFalse(drive.isDriving)
    XCTAssertNil(drive.presentation.sample)
  }

}
