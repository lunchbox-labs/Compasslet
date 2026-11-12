import CarPlay
import CompassCore
import UIKit
import XCTest
@testable import Compass

@MainActor
final class CarPlayPresentationTests: XCTestCase {
  private typealias Sensor = DriveSessionControllerTests.Sensor

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
          accuracyDegrees: 1, timestamp: now), status: .usable),
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

  func testGateReportsTheEndOfTheSlotThatHoldsABearingBack() {
    let start = Date(timeIntervalSince1970: 100)
    let end = start.addingTimeInterval(CarPlayUpdateGate.slot)
    var gate = CarPlayUpdateGate()
    XCTAssertNotNil(gate.update(dialValue(59, at: start), now: start))
    XCTAssertNil(gate.heldUntil)
    // The value already showing isn't held back, so nothing waits for the slot's end.
    XCTAssertNil(gate.update(dialValue(59, at: start), now: start.addingTimeInterval(1)))
    XCTAssertNil(gate.heldUntil)
    for elapsed in [3.0, 9.5] {
      let now = start.addingTimeInterval(elapsed)
      XCTAssertNil(gate.update(dialValue(90, at: now), now: now))
      XCTAssertEqual(gate.heldUntil, end)
    }
    // Passed in again at the end it reported, the held bearing shows.
    let held = dialValue(90, at: end.addingTimeInterval(-0.5), now: end)
    XCTAssertEqual(gate.update(held, now: end)?.courseDegrees, 90)
    XCTAssertNil(gate.heldUntil)
    // A status passes within the next slot and holds nothing; a bearing after it waits.
    let stop = end.addingTimeInterval(1)
    let slow = CarPlayPresentation(
      presentation: .init(sample: nil, status: .slow), setup: .ready, driving: true, now: stop)
    XCTAssertEqual(gate.update(slow, now: stop)?.status, "Stopped or moving too slowly")
    XCTAssertNil(gate.heldUntil)
    let moving = end.addingTimeInterval(2)
    XCTAssertNil(gate.update(dialValue(120, at: moving), now: moving))
    XCTAssertEqual(gate.heldUntil, end.addingTimeInterval(CarPlayUpdateGate.slot))
  }

  func testAHeldBearingShowsWhenItsSlotEndsThoughTheDriveDoesNotChange() async {
    let (drive, sensor, driveClock) = await runningDrive()
    let clock = TestDriveClock(now: driveClock.now)
    var shown: [String] = []
    let updates = CarPlayTemplateUpdates(drive: drive, clock: clock) { next in
      if let next { shown.append(next.bearing) }
    }
    let start = clock.now
    let end = start.addingTimeInterval(CarPlayUpdateGate.slot)
    sensor.receive?(reading(90, at: start))
    updates.update()
    XCTAssertEqual(shown, ["90° E"])
    XCTAssertEqual(clock.pending, [])
    for elapsed in [3.0, 6.0, 9.0] {
      let now = start.addingTimeInterval(elapsed)
      driveClock.now = now
      clock.now = now
      sensor.receive?(reading(180, at: now))
      updates.update()
      // Each change within the slot keeps the one timer for its end.
      XCTAssertEqual(shown, ["90° E"])
      XCTAssertEqual(clock.pending, [end])
    }
    driveClock.now = end
    clock.run(until: end)
    XCTAssertEqual(shown, ["90° E", "180° S"])
    XCTAssertEqual(clock.pending, [])
    updates.stop()
    await drive.endDrive()
  }

  func testAStatusDropsTheSlotTimerAndStoppingDropsAPendingOne() async {
    let (drive, sensor, driveClock) = await runningDrive()
    let clock = TestDriveClock(now: driveClock.now)
    var shown: [String] = []
    let updates = CarPlayTemplateUpdates(drive: drive, clock: clock) { next in
      if let next { shown.append(next.status) }
    }
    let start = clock.now
    func receive(_ course: Double, after elapsed: TimeInterval, speed: Double = 10) {
      let now = start.addingTimeInterval(elapsed)
      driveClock.now = now
      clock.now = now
      sensor.receive?(reading(course, at: now, speed: speed))
      updates.update()
    }
    receive(90, after: 0)
    receive(180, after: 3)
    XCTAssertEqual(clock.pending, [start.addingTimeInterval(CarPlayUpdateGate.slot)])
    // Stopping shows at once, and leaves no bearing waiting for the slot's end.
    receive(180, after: 4, speed: 0)
    XCTAssertEqual(shown.last, "Stopped or moving too slowly")
    XCTAssertEqual(clock.pending, [])
    receive(180, after: 5)
    XCTAssertEqual(clock.pending, [start.addingTimeInterval(CarPlayUpdateGate.slot)])
    // CarPlay disconnecting while the timer is pending cancels it.
    updates.stop()
    XCTAssertEqual(clock.pending, [])
    XCTAssertEqual(shown.count, 2)
    await drive.endDrive()
  }

  func testDriveChangesReachTheTemplateWithoutAPollUntilStopped() async {
    let (drive, sensor, driveClock) = await runningDrive()
    let clock = TestDriveClock(now: driveClock.now)
    var shown: [String] = []
    let updates = CarPlayTemplateUpdates(drive: drive, clock: clock) { next in
      if let next { shown.append(next.status) }
    }
    updates.start()
    XCTAssertEqual(shown, ["Start moving"])
    sensor.receive?(reading(90, at: clock.now, speed: 0))
    for _ in 0..<100 where shown.count < 2 { await Task.yield() }
    XCTAssertEqual(shown, ["Start moving", "Stopped or moving too slowly"])
    updates.stop()
    sensor.receive?(reading(90, at: clock.now))
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(shown, ["Start moving", "Stopped or moving too slowly"])
    await drive.endDrive()
  }

  /// A drive started by CarPlay on a clock that moves only when the test sets it, whose timers
  /// never fire.
  private func runningDrive() async -> (DriveSessionController, Sensor, TestDriveClock) {
    let sensor = Sensor()
    let clock = TestDriveClock()
    let drive = DriveSessionController(
      sensor: sensor, activity: DriveSessionControllerTests.Activity(), clock: clock)
    await drive.carPlayActivated()
    XCTAssertTrue(drive.isDriving)
    return (drive, sensor, clock)
  }

  private func reading(_ course: Double, at timestamp: Date, speed: Double = 10)
    -> TravelSensorEvent
  {
    .reading(
      TravelReading(
        courseDegrees: course, courseAccuracyDegrees: 2, speedMetersPerSecond: speed,
        speedAccuracyMetersPerSecond: 1, horizontalAccuracyMeters: 5, timestamp: timestamp))
  }

  func testNativeHeaderHasNoActionsAndClearsItsCourse() throws {
    let screen = CarPlayCompassTemplate()
    let now = Date(timeIntervalSince1970: 100)
    let car = UITraitCollection(displayScale: 2)
    screen.update(dialValue(59, at: now), traits: car)
    let header = try XCTUnwrap(screen.template.listHeader)
    XCTAssertEqual(header.title, "Sampled 59° NE")
    XCTAssertEqual(
      header.subtitle, now.formatted(date: .omitted, time: .standard))
    XCTAssertEqual(header.bodyVariants.map(\.string), ["Updates limited to once every 10 seconds"])
    XCTAssertTrue(header.actionButtons.isEmpty)
    XCTAssertTrue(screen.template.sections.isEmpty)
    XCTAssertFalse(screen.template.showsSpinnerWhileEmpty)
    XCTAssertEqual(screen.template.emptyViewTitleVariants, [""])
    XCTAssertEqual(screen.template.emptyViewSubtitleVariants, [""])
    screen.update(dialValue(59, at: now, now: now.addingTimeInterval(6)), traits: car)
    XCTAssertEqual(screen.template.listHeader?.title, "—")
    XCTAssertNil(screen.template.listHeader?.subtitle)
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
    XCTAssertEqual(
      try XCTUnwrap(unchanged.thumbnail.image.renderedPixels),
      try XCTUnwrap(before.thumbnail.image.renderedPixels))
    screen.refresh(traits: night)
    let after = try XCTUnwrap(screen.template.listHeader)
    XCTAssertEqual(after.title, before.title)
    XCTAssertEqual(after.subtitle, before.subtitle)
    XCTAssertNotEqual(
      try XCTUnwrap(after.thumbnail.image.renderedPixels),
      try XCTUnwrap(before.thumbnail.image.renderedPixels))
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
    XCTAssertNotEqual(try XCTUnwrap(light.renderedPixels), try XCTUnwrap(image.renderedPixels))
    let unavailable = CarPlayCompassTemplate.dialImage(course: nil, traits: car)
    XCTAssertNotEqual(
      try XCTUnwrap(image.renderedPixels), try XCTUnwrap(unavailable.renderedPixels))
    // Unspecified traits fall back to a one-point scale and the light style.
    let fallback = CarPlayCompassTemplate.dialImage(course: 59, traits: UITraitCollection())
    XCTAssertEqual(fallback.scale, 1)
    XCTAssertEqual(fallback.size, light.size)
  }

  func testDialArrowUsesTheAccentForTheCarsAppearance() throws {
    let accent = try XCTUnwrap(UIColor(named: "AccentColor"))
    for style in [UIUserInterfaceStyle.light, .dark] {
      let car = UITraitCollection { traits in
        traits.displayScale = 1
        traits.userInterfaceStyle = style
      }
      let image = CarPlayCompassTemplate.dialImage(course: 59, traits: car)
      // The dial's centre lies on the arrow's shaft whatever the course.
      let drawn = try XCTUnwrap(centerPixel(of: image))
      let expected = try XCTUnwrap(rgb(accent.resolvedColor(with: car)))
      for (channel, value) in zip(drawn, expected) {
        XCTAssertEqual(channel, value, accuracy: 3, "\(style.rawValue): \(drawn)")
      }
    }
  }

  /// The red, green and blue of the image's center pixel, from 0 to 255, in sRGB.
  private func centerPixel(of image: UIImage) -> [Double]? {
    guard let cgImage = image.cgImage,
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(
        cgImage,
        in: CGRect(
          x: -CGFloat(cgImage.width / 2), y: -CGFloat(cgImage.height / 2),
          width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
      return true
    }
    return drawn ? pixel.prefix(3).map(Double.init) : nil
  }

  /// A color's red, green and blue from 0 to 255, in sRGB.
  private func rgb(_ color: UIColor) -> [Double]? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
      let components = converted.components, components.count >= 3
    else { return nil }
    return components.prefix(3).map { ($0 * 255).rounded() }
  }

  private func dialValue(_ degrees: Double, at timestamp: Date, now: Date? = nil)
    -> CarPlayPresentation
  {
    CarPlayPresentation(
      presentation: .init(
        sample: CompassSample(
          degrees: degrees, source: .vehicleCourse, reference: .trueNorth,
          accuracyDegrees: 1, timestamp: timestamp), status: .usable),
      setup: .ready, driving: true, now: now ?? timestamp)
  }

  func testInvalidStatesNeverExposeBearing() {
    let now = Date()
    let sample = CompassSample(
      degrees: 42, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: 1, timestamp: now)
    for status: TravelStatus in [.waiting, .slow, .unreliable, .unavailable] {
      let value = CarPlayPresentation(
        presentation: .init(sample: sample, status: status),
        setup: .ready, driving: true, now: now)
      XCTAssertEqual(value.bearing, "—")
    }
    let waiting = CarPlayPresentation(
      presentation: .init(sample: nil, status: .waiting), setup: .ready, driving: true, now: now)
    XCTAssertEqual(waiting.status, "Start moving")
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
      accuracyDegrees: 1, timestamp: now)
    let value = CarPlayPresentation(
      presentation: .init(sample: sample, status: .usable),
      setup: .ready, driving: true, now: now)
    XCTAssertEqual(value.bearing, "0° N")
  }

  func testWrongSourceFutureTimeAndNonfiniteInputNeverExposeBearing() {
    let now = Date()
    for sample in [
      CompassSample(
        degrees: 90, source: .deviceHeading, reference: .magnetic,
        accuracyDegrees: 1, timestamp: now),
      CompassSample(
        degrees: 90, source: .vehicleCourse, reference: .trueNorth,
        accuracyDegrees: 1, timestamp: now.addingTimeInterval(1)),
      CompassSample(
        degrees: .infinity, source: .vehicleCourse, reference: .trueNorth,
        accuracyDegrees: 1, timestamp: now),
    ] {
      let value = CarPlayPresentation(
        presentation: .init(sample: sample, status: .usable),
        setup: .ready, driving: true, now: now)
      XCTAssertEqual(value.bearing, "—")
    }
  }

  func testFutureDatedAndMagneticSamplesShowDirectionUnavailable() {
    let now = Date(timeIntervalSince1970: 100)
    for (reference, timestamp) in [
      (NorthReference.trueNorth, now.addingTimeInterval(0.5)), (.magnetic, now),
    ] {
      let value = CarPlayPresentation(
        presentation: .init(
          sample: CompassSample(
            degrees: 90, source: .vehicleCourse, reference: reference,
            accuracyDegrees: 1, timestamp: timestamp), status: .usable),
        setup: .ready, driving: true, now: now)
      XCTAssertEqual(value.bearing, "—")
      XCTAssertNil(value.courseDegrees)
      XCTAssertEqual(value.status, "Direction unavailable")
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
    XCTAssertEqual(events, ["active", "resign", "resign", "disconnect"])
    continuation?.resume()
  }
  func testRealBridgeKeepsTheDriveThroughAShortDisconnectDuringActivityStart() async {
    let sensor = DriveSessionControllerTests.Sensor()
    let activity = DriveSessionControllerTests.Activity()
    activity.pauseStart = true
    let clock = TestDriveClock()
    let drive = DriveSessionController(sensor: sensor, activity: activity, clock: clock)
    let bridge = CarPlayLifecycleBridge(drive: drive)
    bridge.activate()
    for _ in 0..<100 where activity.startContinuation == nil { await Task.yield() }
    XCTAssertNotNil(activity.startContinuation)
    XCTAssertTrue(drive.isDriving)
    bridge.resign()
    XCTAssertTrue(drive.isDriving)
    bridge.disconnect()
    XCTAssertFalse(drive.isCarPlayConnected)
    clock.now += DriveSessionController.carPlayAbsenceLimit
    clock.fireDue()
    XCTAssertTrue(drive.isDriving)
    clock.now += 1
    clock.fireDue()
    XCTAssertFalse(drive.isDriving)
    XCTAssertEqual(sensor.stops, 1)
    activity.startContinuation?.resume()
    await drive.waitForPendingOperations()
    XCTAssertFalse(drive.isDriving)
    XCTAssertNil(drive.presentation.sample)
  }

}
