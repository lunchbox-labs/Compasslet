import CarPlay
import CompassCore
import UIKit
import XCTest
@testable import Compass

@MainActor
final class CarPlayPresentationTests: XCTestCase {
  func testDialUsesOnlyValidatedTrueCourse() {
    let now = Date(timeIntervalSince1970: 100)
    let valid = dialValue(59, at: now)
    XCTAssertEqual(valid.courseDegrees, 59)
    XCTAssertEqual(valid.sampleTimestamp, now)
    let stale = dialValue(59, at: now, now: now.addingTimeInterval(5.01))
    XCTAssertNil(stale.courseDegrees)
    XCTAssertNil(stale.sampleTimestamp)
    let wrongSource = CarPlayPresentation(
      presentation: .init(
        sample: CompassSample(
          degrees: 59, source: .deviceHeading, reference: .magnetic,
          accuracy: 1, timestamp: now), status: .usable),
      setup: .ready, driving: true, compact: .active, now: now)
    XCTAssertNil(wrongSource.courseDegrees)
  }

  func testDisplayedDialExpiresWhileNewCourseWaitsForRateSlot() {
    let start = Date(timeIntervalSince1970: 100)
    var gate = CarPlayUpdateGate()
    XCTAssertEqual(gate.update(dialValue(0, at: start), now: start)?.courseDegrees, 0)
    let boundary = start.addingTimeInterval(5)
    XCTAssertNil(gate.update(dialValue(90, at: boundary), now: boundary))
    let expired = start.addingTimeInterval(5.01)
    let cleared = gate.update(dialValue(90, at: expired), now: expired)
    XCTAssertNotNil(cleared)
    XCTAssertNil(cleared?.courseDegrees)
    XCTAssertEqual(cleared?.bearing, "—")
    let early = start.addingTimeInterval(9.99)
    XCTAssertNil(gate.update(dialValue(90, at: early), now: early))
    let due = start.addingTimeInterval(10)
    XCTAssertEqual(gate.update(dialValue(90, at: due), now: due)?.courseDegrees, 90)
  }

  func testInvalidationBypassesRateLimitButRecoveryDoesNot() {
    let start = Date(timeIntervalSince1970: 100)
    var gate = CarPlayUpdateGate()
    _ = gate.update(dialValue(0, at: start), now: start)
    let invalid = CarPlayPresentation(
      presentation: .init(sample: nil, status: .unreliable), setup: .ready,
      driving: true, compact: .active, now: start.addingTimeInterval(1))
    XCTAssertEqual(gate.update(invalid, now: start.addingTimeInterval(1))?.bearing, "—")
    let recovery = start.addingTimeInterval(2)
    XCTAssertNil(gate.update(dialValue(90, at: recovery), now: recovery))
  }

  func testNativeHeaderHasNoActionsAndClearsItsCourse() throws {
    let screen = CarPlayCompassTemplate()
    let now = Date(timeIntervalSince1970: 100)
    screen.update(dialValue(59, at: now))
    let header = try XCTUnwrap(screen.template.listHeader)
    XCTAssertEqual(header.title, "59° NE")
    XCTAssertTrue(header.actionButtons.isEmpty)
    XCTAssertTrue(screen.template.sections.isEmpty)
    XCTAssertFalse(screen.template.showsSpinnerWhileEmpty)
    XCTAssertEqual(screen.template.emptyViewTitleVariants, [""])
    XCTAssertEqual(screen.template.emptyViewSubtitleVariants, [""])
    screen.update(dialValue(59, at: now, now: now.addingTimeInterval(6)))
    XCTAssertEqual(screen.template.listHeader?.title, "—")
    XCTAssertEqual(screen.template.listHeader?.subtitle, "Travel · True north")
  }

  func testDialSnapshotFitsThumbnailLimitAndHasAppearanceVariants() throws {
    let image = CarPlayCompassTemplate.dialImage(course: 59)
    let maximum = CPThumbnailImage.maximumImageSize(forAspectRatio: 1)
    XCTAssertGreaterThan(image.size.width, 0)
    XCTAssertLessThanOrEqual(image.size.width, maximum.width)
    XCTAssertLessThanOrEqual(image.size.height, maximum.height)
    let asset = try XCTUnwrap(image.imageAsset)
    let light = asset.image(with: UITraitCollection(userInterfaceStyle: .light))
    let dark = asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
    XCTAssertNotEqual(light.pngData(), dark.pngData())
    let unavailable = CarPlayCompassTemplate.dialImage(course: nil)
    XCTAssertNotEqual(image.pngData(), unavailable.pngData())
  }

  private func dialValue(_ degrees: Double, at timestamp: Date, now: Date? = nil)
    -> CarPlayPresentation
  {
    CarPlayPresentation(
      presentation: .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracy: 1, timestamp: timestamp), status: .usable),
      setup: .ready, driving: true, compact: .active, now: now ?? timestamp)
  }

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
      resign: { events.append("resign") }, disconnect: { events.append("disconnect") })
    bridge.activate()
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    XCTAssertNotNil(continuation)
    bridge.resign()
    XCTAssertEqual(events, ["active", "resign"])
    bridge.disconnect()
    for _ in 0..<100 where !events.contains("disconnect") {
      await Task.yield()
    }
    XCTAssertTrue(events.contains("disconnect"))
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
