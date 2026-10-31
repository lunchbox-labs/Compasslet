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
      setup: .ready, driving: true, now: now)
    XCTAssertNil(wrongSource.courseDegrees)
  }

  func testFreshChangingAndUnchangedStreamsKeepTimestampedSnapshotsBetweenSlots() {
    let start = Date(timeIntervalSince1970: 100)
    for changing in [false, true] {
      var gate = CarPlayUpdateGate()
      var displayed: CarPlayPresentation?
      var updateTimes: [Double] = []
      for tick in 0...120 {
        let elapsed = Double(tick) / 4
        let now = start.addingTimeInterval(elapsed)
        let course = changing ? Double(tick) : 59
        if let next = gate.update(dialValue(course, at: now), now: now) {
          displayed = next
          updateTimes.append(elapsed)
        }
        XCTAssertNotNil(displayed?.courseDegrees)
        // The visible timestamp belongs to the sampled slot, never to intervening input.
        let slot = floor(elapsed / 10) * 10
        XCTAssertEqual(displayed?.sampleTimestamp, start.addingTimeInterval(slot))
        XCTAssertEqual(displayed?.courseDegrees, changing ? slot * 4 : 59)
      }
      XCTAssertEqual(updateTimes, [0, 10, 20, 30])
    }
  }

  func testDelayedFreshInputDoesNotExtendDisplayedTimestampAndLossClearsIt() {
    let start = Date(timeIntervalSince1970: 100)
    var gate = CarPlayUpdateGate()
    let original = start.addingTimeInterval(-4.5)
    let first = gate.update(dialValue(59, at: original, now: start), now: start)
    XCTAssertEqual(first?.sampleTimestamp, original)
    for elapsed in [1.0, 5.0, 9.75] {
      let now = start.addingTimeInterval(elapsed)
      XCTAssertNil(
        gate.update(
          dialValue(90, at: now.addingTimeInterval(-4.5), now: now), now: now))
    }
    // Genuine input loss: the most recent sensor sample is now older than five seconds.
    let failure = start.addingTimeInterval(10.5)
    let lastSensorTime = start.addingTimeInterval(5.25)
    let cleared = gate.update(dialValue(90, at: lastSensorTime, now: failure), now: failure)
    XCTAssertNotNil(cleared)
    XCTAssertNil(cleared?.courseDegrees)
    XCTAssertNil(cleared?.sampleTimestamp)
  }

  func testInputLossOrPermissionLossClearsSnapshotBeforeNextSlot() {
    let start = Date(timeIntervalSince1970: 100)
    for permissionLost in [false, true] {
      var gate = CarPlayUpdateGate()
      _ = gate.update(dialValue(59, at: start), now: start)
      let now = start.addingTimeInterval(permissionLost ? 1 : 5.25)
      let input =
        permissionLost
        ? CarPlayPresentation(
          presentation: .init(sample: nil, status: .unavailable), setup: .denied,
          driving: false, now: now)
        : dialValue(59, at: start, now: now)
      let cleared = gate.update(input, now: now)
      XCTAssertNotNil(cleared)
      XCTAssertNil(cleared?.courseDegrees)
      XCTAssertNil(cleared?.sampleTimestamp)
    }
  }

  func testInvalidationBypassesRateLimitButRecoveryDoesNot() {
    let start = Date(timeIntervalSince1970: 100)
    var gate = CarPlayUpdateGate()
    _ = gate.update(dialValue(0, at: start), now: start)
    let invalid = CarPlayPresentation(
      presentation: .init(sample: nil, status: .unreliable), setup: .ready,
      driving: true, now: start.addingTimeInterval(1))
    XCTAssertEqual(gate.update(invalid, now: start.addingTimeInterval(1))?.bearing, "—")
    let recovery = start.addingTimeInterval(2)
    XCTAssertNil(gate.update(dialValue(90, at: recovery), now: recovery))
  }

  func testNativeHeaderHasNoActionsAndClearsItsCourse() throws {
    let screen = CarPlayCompassTemplate()
    let now = Date(timeIntervalSince1970: 100)
    let car = UITraitCollection(displayScale: 2)
    screen.update(dialValue(59, at: now), traits: car)
    let header = try XCTUnwrap(screen.template.listHeader)
    XCTAssertEqual(header.title, "Sampled 59° NE")
    XCTAssertEqual(
      header.subtitle, "Travel · True North · \(now.formatted(date: .omitted, time: .standard))")
    XCTAssertEqual(header.bodyVariants.map(\.string), ["Updates limited to once every 10 seconds"])
    XCTAssertTrue(header.actionButtons.isEmpty)
    XCTAssertTrue(screen.template.sections.isEmpty)
    XCTAssertFalse(screen.template.showsSpinnerWhileEmpty)
    XCTAssertEqual(screen.template.emptyViewTitleVariants, [""])
    XCTAssertEqual(screen.template.emptyViewSubtitleVariants, [""])
    screen.update(dialValue(59, at: now, now: now.addingTimeInterval(6)), traits: car)
    XCTAssertEqual(screen.template.listHeader?.title, "—")
    XCTAssertEqual(screen.template.listHeader?.subtitle, "Travel · True North")
  }

  func testStyleChangeRedrawsTheCurrentContentWithoutANewValue() throws {
    let screen = CarPlayCompassTemplate()
    let now = Date(timeIntervalSince1970: 100)
    let day = UITraitCollection { traits in
      traits.displayScale = 2
      traits.userInterfaceStyle = .light
    }
    let night = UITraitCollection { traits in
      traits.displayScale = 2
      traits.userInterfaceStyle = .dark
    }
    screen.update(dialValue(59, at: now), traits: day)
    let before = try XCTUnwrap(screen.template.listHeader)
    screen.refresh(traits: day)
    let unchanged = try XCTUnwrap(screen.template.listHeader)
    XCTAssertEqual(unchanged.title, before.title)
    XCTAssertEqual(unchanged.subtitle, before.subtitle)
    XCTAssertEqual(unchanged.thumbnail.image.pngData(), before.thumbnail.image.pngData())
    screen.refresh(traits: night)
    let after = try XCTUnwrap(screen.template.listHeader)
    XCTAssertEqual(after.title, before.title)
    XCTAssertEqual(after.subtitle, before.subtitle)
    XCTAssertNotEqual(after.thumbnail.image.pngData(), before.thumbnail.image.pngData())
  }

  func testDialSnapshotFitsThumbnailLimitAndMatchesCarScaleAndStyle() throws {
    let car = UITraitCollection { traits in
      traits.displayScale = 2
      traits.userInterfaceStyle = .dark
    }
    let image = CarPlayCompassTemplate.dialImage(course: 59, traits: car)
    let maximum = CPThumbnailImage.maximumImageSize(forAspectRatio: 1)
    XCTAssertGreaterThan(image.size.width, 0)
    XCTAssertLessThanOrEqual(image.size.width, maximum.width)
    XCTAssertLessThanOrEqual(image.size.height, maximum.height)
    XCTAssertEqual(image.scale, 2)
    let light = CarPlayCompassTemplate.dialImage(
      course: 59,
      traits: UITraitCollection { traits in
        traits.displayScale = 2
        traits.userInterfaceStyle = .light
      })
    XCTAssertNotEqual(light.pngData(), image.pngData())
    let unavailable = CarPlayCompassTemplate.dialImage(course: nil, traits: car)
    XCTAssertNotEqual(image.pngData(), unavailable.pngData())
    // Unspecified traits fall back to a one-point scale and the light style.
    let fallback = CarPlayCompassTemplate.dialImage(course: 59, traits: UITraitCollection())
    XCTAssertEqual(fallback.scale, 1)
    XCTAssertEqual(fallback.size, light.size)
  }

  private func dialValue(_ degrees: Double, at timestamp: Date, now: Date? = nil)
    -> CarPlayPresentation
  {
    CarPlayPresentation(
      presentation: .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracy: 1, timestamp: timestamp), status: .usable),
      setup: .ready, driving: true, now: now ?? timestamp)
  }

  func testInvalidStatesNeverExposeBearing() {
    let now = Date()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: now)
    for status: TravelStatus in [.waiting, .slow, .unreliable, .unavailable] {
      let value = CarPlayPresentation(
        presentation: .init(sample: sample, status: status),
        setup: .ready, driving: true, now: now)
      XCTAssertEqual(value.bearing, "—")
    }
    let stale = CarPlayPresentation(
      presentation: .init(sample: sample, status: .usable),
      setup: .ready, driving: true, now: now.addingTimeInterval(6))
    XCTAssertEqual(stale.bearing, "—")
    let setup = CarPlayPresentation(
      presentation: .init(sample: sample, status: .usable),
      setup: .permissionRequired, driving: false, now: now)
    XCTAssertEqual(setup.bearing, "—")
    XCTAssertTrue(setup.status.contains("parked"))
  }

  func testTrueNorthCourseRounding() {
    let now = Date()
    let sample = CompassSample(
      degrees: 359.8, source: .vehicleCourse, reference: .trueNorth,
      accuracy: 1, timestamp: now)
    let value = CarPlayPresentation(
      presentation: .init(sample: sample, status: .usable),
      setup: .ready, driving: true, now: now)
    XCTAssertEqual(value.bearing, "0° N")
    XCTAssertEqual(value.reference, "Travel · True North")
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
        setup: .ready, driving: true, now: now)
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
