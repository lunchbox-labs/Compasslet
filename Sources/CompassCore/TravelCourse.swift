import Foundation

/// Travel measurements without position or route information.
public struct TravelReading: Sendable, Equatable {
  /// Travel direction in degrees clockwise from true north.
  public let course: Double
  /// Course uncertainty in degrees.
  public let courseAccuracy: Double
  /// Travel speed in metres per second.
  public let speed: Double
  /// Speed uncertainty in metres per second.
  public let speedAccuracy: Double
  /// Horizontal position uncertainty in metres; no position is retained.
  public let horizontalAccuracy: Double
  /// Acquisition time of these measurements.
  public let timestamp: Date

  /// Creates travel measurements for validation by the filter.
  public init(
    course: Double, courseAccuracy: Double, speed: Double, speedAccuracy: Double,
    horizontalAccuracy: Double, timestamp: Date
  ) {
    self.course = course
    self.courseAccuracy = courseAccuracy
    self.speed = speed
    self.speedAccuracy = speedAccuracy
    self.horizontalAccuracy = horizontalAccuracy
    self.timestamp = timestamp
  }
}

/// Whether a vehicle travel direction can currently be presented.
public enum TravelStatus: Sendable, Equatable {
  case waiting, usable, slow, unreliable, unavailable
}

/// A bearing is present only when the travel measurements are usable.
public struct TravelPresentation: Sendable, Equatable {
  /// The usable smoothed direction, or nil when unavailable.
  public let sample: CompassSample?
  /// The current travel measurement status.
  public let status: TravelStatus

  /// Creates the current bearing and status presentation.
  public init(sample: CompassSample?, status: TravelStatus) {
    self.sample = sample
    self.status = status
  }
}

/// Validates travel measurements and smooths usable true-north vehicle course.
public struct TravelCourseFilter: Sendable {
  private var smoother: CompassSmoother
  private var previousTimestamp: Date?

  /// Creates an empty travel-course smoothing sequence.
  public init() {
    guard let smoother = CompassSmoother(fraction: 0.25) else {
      preconditionFailure("The fixed smoothing fraction must be valid")
    }
    self.smoother = smoother
  }

  /// Discards the current smoothing sequence.
  public mutating func reset() {
    smoother.reset()
    previousTimestamp = nil
  }

  /// Rejects missing, old, future, inaccurate, or insufficient movement measurements.
  /// Non-increasing timestamps and gaps over five seconds start a new sequence.
  public mutating func update(_ reading: TravelReading?, now: Date) -> TravelPresentation {
    guard let reading, now.timeIntervalSince1970.isFinite,
      reading.timestamp.timeIntervalSince1970.isFinite
    else { return reject(.unavailable) }
    let age = now.timeIntervalSince(reading.timestamp)
    guard age.isFinite, age >= 0, age <= 5 else { return reject(.unavailable) }
    guard reading.speed.isFinite, reading.speed >= 2,
      reading.speedAccuracy.isFinite, reading.speedAccuracy >= 0,
      reading.speed - reading.speedAccuracy >= 1
    else { return reject(.slow) }
    guard reading.course.isFinite, reading.course >= 0, reading.course < 360,
      reading.courseAccuracy.isFinite, reading.courseAccuracy >= 0,
      reading.courseAccuracy <= 30, reading.horizontalAccuracy.isFinite,
      reading.horizontalAccuracy >= 0, reading.horizontalAccuracy <= 50
    else { return reject(.unreliable) }

    if let previousTimestamp, reading.timestamp <= previousTimestamp {
      smoother.reset()
    }
    let sample = CompassSample(
      degrees: reading.course, source: .vehicleCourse, reference: .trueNorth,
      accuracy: reading.courseAccuracy, timestamp: reading.timestamp)
    let smoothed = smoother.update(sample, now: now, maximumAge: 5)
    previousTimestamp = reading.timestamp
    return TravelPresentation(sample: smoothed, status: .usable)
  }

  private mutating func reject(_ status: TravelStatus) -> TravelPresentation {
    reset()
    return TravelPresentation(sample: nil, status: status)
  }
}
