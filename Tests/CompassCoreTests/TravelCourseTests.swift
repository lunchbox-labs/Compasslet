import Foundation
import Testing
import CompassCore

struct TravelCourseTests {
  private let time = Date(timeIntervalSince1970: 100)

  private func reading(
    course: Double = 90, courseAccuracy: Double = 1, speed: Double = 3,
    speedAccuracy: Double = 1, horizontalAccuracy: Double = 1,
    offset: Double = 0
  ) -> TravelReading {
    TravelReading(
      courseDegrees: course, courseAccuracyDegrees: courseAccuracy, speedMetersPerSecond: speed,
      speedAccuracyMetersPerSecond: speedAccuracy, horizontalAccuracyMeters: horizontalAccuracy,
      timestamp: time.addingTimeInterval(offset))
  }

  @Test func acceptsInclusiveAccuracyMovementAndAgeBoundaries() {
    for course in [0.0, 359.999] {
      for age in [0.0, 5.0] {
        var filter = TravelCourseFilter()
        let result = filter.update(
          reading(
            course: course, courseAccuracy: 30,
            speed: 2, speedAccuracy: 1, horizontalAccuracy: 50, offset: -age), now: time)
        #expect(result.status == .usable)
        #expect(result.sample?.angle.degrees == course)
        #expect(result.sample?.source == .vehicleCourse)
        #expect(result.sample?.reference == .trueNorth)
        #expect(result.sample?.accuracyDegrees == 30)
        #expect(result.sample?.timestamp == time.addingTimeInterval(-age))
      }
    }
    var filter = TravelCourseFilter()
    #expect(
      filter.update(
        reading(
          courseAccuracy: 0, speedAccuracy: 0,
          horizontalAccuracy: 0), now: time
      ).status == .usable)
  }

  @Test func rejectsInvalidCourseAndAccuracyWithoutBearing() {
    let invalid = [-1.0, Double.nan, Double.infinity, -Double.infinity]
    var cases = invalid.map { reading(course: $0) }
    cases += [reading(course: 360), reading(course: 360.001)]
    cases += (invalid + [30.001]).map { reading(courseAccuracy: $0) }
    cases += (invalid + [50.001]).map { reading(horizontalAccuracy: $0) }
    for input in cases {
      var filter = TravelCourseFilter()
      let result = filter.update(input, now: time)
      #expect(result.status == .unreliable)
      #expect(result.sample == nil)
    }
  }

  @Test func rejectsInvalidMovementWithoutBearing() {
    let invalid = [-1.0, Double.nan, Double.infinity, -Double.infinity]
    let cases =
      (invalid + [0, 1.999]).map { reading(speed: $0) }
      + invalid.map { reading(speedAccuracy: $0) }
      + [reading(speed: 2, speedAccuracy: 1.001)]
    for input in cases {
      var filter = TravelCourseFilter()
      let result = filter.update(input, now: time)
      #expect(result.status == .slow)
      #expect(result.sample == nil)
    }
  }

  @Test func absentInvalidOrStaleTimeIsUnavailable() {
    for offset in [-5.001, 0.001, Double.nan, Double.infinity, -Double.infinity] {
      var filter = TravelCourseFilter()
      let result = filter.update(reading(offset: offset), now: time)
      #expect(result.status == .unavailable)
      #expect(result.sample == nil)
    }
    for seconds in [Double.nan, Double.infinity, -Double.infinity] {
      var filter = TravelCourseFilter()
      let result = filter.update(reading(), now: Date(timeIntervalSince1970: seconds))
      #expect(result.status == .unavailable)
      #expect(result.sample == nil)
    }
    var filter = TravelCourseFilter()
    #expect(filter.update(nil, now: time).status == .unavailable)
  }

  @Test func smoothsAcrossNorthWithNewMetadata() {
    var filter = TravelCourseFilter()
    _ = filter.update(reading(course: 359), now: time)
    let result = filter.update(
      reading(course: 1, courseAccuracy: 2, offset: 1),
      now: time.addingTimeInterval(1))
    #expect(result.sample?.angle.degrees == 359.5)
    #expect(result.sample?.accuracyDegrees == 2)
    #expect(result.sample?.timestamp == time.addingTimeInterval(1))
  }

  @Test func halfOfATurnSizedChangeAdoptsHalfOfIt() {
    var filter = TravelCourseFilter()
    _ = filter.update(reading(course: 90), now: time)
    #expect(
      filter.update(reading(course: 100, offset: 1), now: time.addingTimeInterval(1))
        .sample?.angle.degrees == 95)
  }

  @Test func turnSizedChangeIsAdoptedOutright() {
    var filter = TravelCourseFilter()
    _ = filter.update(reading(course: 90), now: time)
    #expect(
      filter.update(reading(course: 110, offset: 1), now: time.addingTimeInterval(1))
        .sample?.angle.degrees == 110)
    #expect(
      filter.update(reading(course: 200, offset: 2), now: time.addingTimeInterval(2))
        .sample?.angle.degrees == 200)
  }

  @Test func jitterOfAFewDegreesKeepsTheQuarterFraction() {
    var filter = TravelCourseFilter()
    _ = filter.update(reading(course: 180), now: time)
    #expect(
      filter.update(reading(course: 182, offset: 1), now: time.addingTimeInterval(1))
        .sample?.angle.degrees == 180.5)
  }

  @Test func smoothingCrossesNorthByShortestRotation() {
    var northward = TravelCourseFilter()
    _ = northward.update(reading(course: 5), now: time)
    #expect(
      northward.update(reading(course: 350, offset: 1), now: time.addingTimeInterval(1))
        .sample?.angle.degrees == 353.75)
  }

  @Test func invalidDataAndExplicitResetClearSmoothing() {
    let invalid: [TravelReading?] = [
      nil, reading(speed: 0), reading(course: -1),
      reading(offset: -6),
    ]
    for input in invalid {
      var filter = TravelCourseFilter()
      _ = filter.update(reading(course: 90), now: time)
      #expect(filter.update(input, now: time).sample == nil)
      #expect(filter.update(reading(course: 180), now: time).sample?.angle.degrees == 180)
    }
    var filter = TravelCourseFilter()
    _ = filter.update(reading(), now: time)
    filter.reset()
    #expect(filter.update(reading(course: 180), now: time).sample?.angle.degrees == 180)
  }

  @Test func gapsReversedAndDuplicateTimestampsStartNewSequence() {
    for offset in [-1.0, 0, 6] {
      var filter = TravelCourseFilter()
      _ = filter.update(reading(), now: time)
      let result = filter.update(
        reading(course: 180, offset: offset),
        now: time.addingTimeInterval(max(0, offset)))
      #expect(result.sample?.angle.degrees == 180)
    }
  }

  private func travelSample(
    degrees: Double = 90, source: CompassSource = .vehicleCourse,
    reference: NorthReference = .trueNorth
  ) -> CompassSample? {
    CompassSample(
      degrees: degrees, source: source, reference: reference, accuracyDegrees: 1, timestamp: time)
  }

  @Test func aTravelSampleIsCurrentForFiveSecondsFromItsTime() throws {
    let sample = try #require(travelSample())
    #expect(CompassSample.travelLifetime == 5)
    #expect(sample.isCurrent(at: time))
    #expect(sample.isCurrent(at: time.addingTimeInterval(5)))
    #expect(!sample.isCurrent(at: time.addingTimeInterval(5.001)))
    // A sample dated after the clock isn't current, as the drive's expiry treats it.
    #expect(!sample.isCurrent(at: time.addingTimeInterval(-0.001)))
  }

  @Test func onlyACurrentBearingThatAgedPastFiveSecondsHasExpired() throws {
    let sample = try #require(travelSample())
    #expect(!sample.hasExpired(at: time))
    #expect(!sample.hasExpired(at: time.addingTimeInterval(5)))
    #expect(sample.hasExpired(at: time.addingTimeInterval(5.001)))
    // Dated after the clock, it isn't current, but it hasn't aged either.
    #expect(!sample.hasExpired(at: time.addingTimeInterval(-1)))
    for now in [Double.nan, .infinity, -.infinity] {
      #expect(!sample.hasExpired(at: Date(timeIntervalSince1970: now)))
    }
    let later = time.addingTimeInterval(10)
    #expect(try !#require(travelSample(reference: .magnetic)).hasExpired(at: later))
    #expect(try !#require(travelSample(source: .deviceHeading)).hasExpired(at: later))
  }

  @Test func onlyAFiniteClockMakesATravelSampleCurrent() throws {
    let sample = try #require(travelSample())
    for now in [Double.nan, .infinity, -.infinity] {
      #expect(!sample.isCurrent(at: Date(timeIntervalSince1970: now)))
    }
  }

  @Test func onlyTheVehicleCourseAgainstTrueNorthIsACurrentTravelBearing() throws {
    #expect(try #require(travelSample()).isCurrent(at: time))
    #expect(try !#require(travelSample(reference: .magnetic)).isCurrent(at: time))
    #expect(try !#require(travelSample(source: .deviceHeading)).isCurrent(at: time))
    #expect(
      try !#require(travelSample(source: .deviceHeading, reference: .magnetic)).isCurrent(at: time))
  }

  @Test func headingsOutside0To360NeverReachTheRule() throws {
    // A sample can't hold a heading outside 0..<360: 360 becomes north, and negative or
    // nonfinite headings make no sample, so the rule's range check never rejects a real one.
    let north = try #require(travelSample(degrees: 360))
    #expect(north.angle.degrees == 0)
    #expect(north.isCurrent(at: time))
    #expect(try #require(travelSample(degrees: 359.999)).isCurrent(at: time))
    for degrees in [-0.001, -90, .nan, .infinity, -.infinity, 360.001] {
      #expect(travelSample(degrees: degrees) == nil)
    }
  }
}
