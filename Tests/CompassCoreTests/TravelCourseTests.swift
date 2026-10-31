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
      course: course, courseAccuracy: courseAccuracy, speed: speed,
      speedAccuracy: speedAccuracy, horizontalAccuracy: horizontalAccuracy,
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
        #expect(result.sample?.accuracy == 30)
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
    #expect(result.sample?.accuracy == 2)
    #expect(result.sample?.timestamp == time.addingTimeInterval(1))
  }

  @Test func turnsAreFollowedPromptlyWhileSmallChangesAreDamped() {
    var filter = TravelCourseFilter()
    _ = filter.update(reading(course: 90), now: time)
    // Ten degrees is half a turn-sized change, so half of it is adopted.
    #expect(
      filter.update(reading(course: 100, offset: 1), now: time.addingTimeInterval(1))
        .sample?.angle.degrees == 95)
    // A 20-degree or larger change is adopted outright.
    #expect(
      filter.update(reading(course: 180, offset: 2), now: time.addingTimeInterval(2))
        .sample?.angle.degrees == 180)
    // Jitter of a couple of degrees keeps the quarter fraction.
    #expect(
      filter.update(reading(course: 182, offset: 3), now: time.addingTimeInterval(3))
        .sample?.angle.degrees == 180.5)
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
}
