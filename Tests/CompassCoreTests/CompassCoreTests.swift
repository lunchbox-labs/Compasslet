import Foundation
import Testing
import CompassCore

@Test func normalizedAnglesAndShortestDeltas() throws {
  let north = try #require(CompassAngle(degrees: 720))
  #expect(north.degrees == 0)
  #expect(CompassAngle(degrees: -1)?.degrees == 359)
  #expect(CompassAngle(degrees: .nan) == nil)
  #expect(CompassAngle(degrees: .infinity) == nil)
  let west = try #require(CompassAngle(degrees: 359))
  let east = try #require(CompassAngle(degrees: 1))
  #expect(west.shortestDelta(to: east) == 2)
  #expect(east.shortestDelta(to: west) == -2)
  let south = try #require(CompassAngle(degrees: 180))
  #expect(north.shortestDelta(to: south) == 180)
  #expect(south.shortestDelta(to: north) == 180)
}

private let instant = Date(timeIntervalSince1970: 100)
private func sample(
  _ degrees: Double = 0, source: CompassSource = .deviceHeading,
  reference: NorthReference = .magnetic, accuracy: Double = 1,
  timestamp: Date = instant
) -> CompassSample? {
  CompassSample(
    degrees: degrees, source: source, reference: reference,
    accuracy: accuracy, timestamp: timestamp)
}

@Test func sampleValidityAndMetadata() throws {
  let reading = try #require(sample(source: .vehicleCourse, reference: .trueNorth))
  #expect(reading.angle.degrees == 0)
  #expect(reading.source == .vehicleCourse)
  #expect(reading.reference == .trueNorth)
  #expect(sample(-1) == nil)
  #expect(sample(361) == nil)
  #expect(sample(.nan) == nil)
  #expect(sample(accuracy: -1) == nil)
  #expect(sample(accuracy: .infinity) == nil)
  #expect(sample(timestamp: Date(timeIntervalSince1970: .nan)) == nil)
}

@Test func freshnessIncludesBoundaryAndRejectsFuture() throws {
  let reading = try #require(sample())
  #expect(reading.isFresh(now: instant, maximumAge: 0))
  #expect(reading.isFresh(now: instant.addingTimeInterval(5), maximumAge: 5))
  #expect(!reading.isFresh(now: instant.addingTimeInterval(5.001), maximumAge: 5))
  #expect(!reading.isFresh(now: instant.addingTimeInterval(-1), maximumAge: 5))
  #expect(!reading.isFresh(now: instant, maximumAge: -1))
  #expect(!reading.isFresh(now: instant, maximumAge: .infinity))
  #expect(!reading.isFresh(now: Date(timeIntervalSince1970: .nan), maximumAge: 5))
}

@Test func smoothingCrossesNorthAndResets() throws {
  var smoother = try #require(CompassSmoother(fraction: 0.5))
  #expect(smoother.update(sample(359), now: instant, maximumAge: 5)?.angle.degrees == 359)
  #expect(smoother.update(sample(1), now: instant, maximumAge: 5)?.angle.degrees == 0)
  #expect(
    smoother.update(
      sample(90, source: .vehicleCourse), now: instant,
      maximumAge: 5)?.angle.degrees == 90)
  #expect(
    smoother.update(
      sample(180, source: .vehicleCourse, reference: .trueNorth),
      now: instant, maximumAge: 5)?.angle.degrees == 180)
  #expect(smoother.update(nil, now: instant, maximumAge: 5) == nil)
  #expect(smoother.update(sample(270), now: instant, maximumAge: 5)?.angle.degrees == 270)
  smoother.reset()
  #expect(smoother.update(sample(0), now: instant, maximumAge: 5)?.angle.degrees == 0)
}

@Test func smoothingResetsAfterStaleGapAndOutOfOrderInput() throws {
  var smoother = try #require(CompassSmoother(fraction: 0.5))
  _ = smoother.update(sample(90), now: instant, maximumAge: 5)
  let later = instant.addingTimeInterval(10)
  #expect(
    smoother.update(
      sample(180, timestamp: later), now: later,
      maximumAge: 5)?.angle.degrees == 180)
  #expect(smoother.update(sample(0), now: later, maximumAge: 5) == nil)
  #expect(
    smoother.update(
      sample(270, timestamp: later), now: later,
      maximumAge: 5)?.angle.degrees == 270)
  #expect(CompassSmoother(fraction: 0) == nil)
  #expect(CompassSmoother(fraction: .nan) == nil)
  #expect(CompassSmoother(fraction: 1.1) == nil)
  #expect(CompassSmoother(fraction: 0.5, fullTrackingDelta: 0) == nil)
  #expect(CompassSmoother(fraction: 0.5, fullTrackingDelta: -10) == nil)
  #expect(CompassSmoother(fraction: 0.5, fullTrackingDelta: .nan) == nil)
  #expect(CompassSmoother(fraction: 0.5, fullTrackingDelta: .infinity) == nil)
}

@Test func fullTrackingDeltaFollowsLargeChangesAndDampsSmallOnes() throws {
  var smoother = try #require(CompassSmoother(fraction: 0.5, fullTrackingDelta: 10))
  #expect(smoother.update(sample(0), now: instant, maximumAge: 5)?.angle.degrees == 0)
  // A 3-degree change is below the floor's reach, so the configured fraction applies.
  #expect(smoother.update(sample(3), now: instant, maximumAge: 5)?.angle.degrees == 1.5)
  // A change at or beyond the full-tracking size is adopted outright.
  #expect(smoother.update(sample(21.5), now: instant, maximumAge: 5)?.angle.degrees == 21.5)
  // A 7.5-degree change scales to three quarters, between the floor and full tracking.
  #expect(smoother.update(sample(14), now: instant, maximumAge: 5)?.angle.degrees == 15.875)
  smoother.reset()
  _ = smoother.update(sample(2), now: instant, maximumAge: 5)
  // The scaled step crosses north by the shortest rotation.
  #expect(smoother.update(sample(354.5), now: instant, maximumAge: 5)?.angle.degrees == 356.375)
}

@Test func tinyNegativeAngleRemainsBelowFullTurn() throws {
  let angle = try #require(CompassAngle(degrees: -Double.leastNonzeroMagnitude))
  #expect(angle.degrees >= 0)
  #expect(angle.degrees < 360)
}

@Test func reversedFreshTimestampsStartNewSequence() throws {
  var smoother = try #require(CompassSmoother(fraction: 0.5))
  let newer = instant.addingTimeInterval(2)
  _ = smoother.update(sample(90, timestamp: newer), now: newer, maximumAge: 5)
  let updated = smoother.update(sample(180), now: newer, maximumAge: 5)
  let result = try #require(updated)
  #expect(result.angle.degrees == 180)
  #expect(result.timestamp == instant)
  #expect(result.accuracy == 1)
}

@Test func futureInputClearsSmoothingState() throws {
  var smoother = try #require(CompassSmoother(fraction: 0.5))
  _ = smoother.update(sample(90), now: instant, maximumAge: 5)
  #expect(
    smoother.update(
      sample(180, timestamp: instant.addingTimeInterval(1)),
      now: instant, maximumAge: 5) == nil)
  #expect(smoother.update(sample(270), now: instant, maximumAge: 5)?.angle.degrees == 270)
}
