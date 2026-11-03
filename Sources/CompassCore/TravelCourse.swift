import Foundation

/// Travel measurements without position or route information.
public struct TravelReading: Sendable, Equatable {
  /// Clockwise from true north.
  public let courseDegrees: Double
  public let courseAccuracyDegrees: Double
  public let speedMetersPerSecond: Double
  public let speedAccuracyMetersPerSecond: Double
  /// Only the uncertainty is kept; no position is retained.
  public let horizontalAccuracyMeters: Double
  public let timestamp: Date

  public init(
    courseDegrees: Double,
    courseAccuracyDegrees: Double,
    speedMetersPerSecond: Double,
    speedAccuracyMetersPerSecond: Double,
    horizontalAccuracyMeters: Double,
    timestamp: Date
  ) {
    self.courseDegrees = courseDegrees
    self.courseAccuracyDegrees = courseAccuracyDegrees
    self.speedMetersPerSecond = speedMetersPerSecond
    self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
    self.horizontalAccuracyMeters = horizontalAccuracyMeters
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
  public let status: TravelStatus

  public init(sample: CompassSample?, status: TravelStatus) {
    self.sample = sample
    self.status = status
  }
}

/// Validates travel measurements and smooths usable true-north vehicle course.
public struct TravelCourseFilter: Sendable {
  private var smoother: CompassSmoother
  private var previousTimestamp: Date?

  /// Location course arrives about once a second and is already filtered by the hardware, so
  /// small changes are damped while a turn-sized change of 20 degrees or more is adopted at once.
  public init() {
    guard let smoother = CompassSmoother(fraction: 0.25, fullTrackingDelta: 20) else {
      preconditionFailure("The fixed smoothing fraction must be valid")
    }
    self.smoother = smoother
  }

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
    guard reading.speedMetersPerSecond.isFinite, reading.speedMetersPerSecond >= 2,
      reading.speedAccuracyMetersPerSecond.isFinite, reading.speedAccuracyMetersPerSecond >= 0,
      reading.speedMetersPerSecond - reading.speedAccuracyMetersPerSecond >= 1
    else { return reject(.slow) }
    guard reading.courseDegrees.isFinite, reading.courseDegrees >= 0, reading.courseDegrees < 360,
      reading.courseAccuracyDegrees.isFinite, reading.courseAccuracyDegrees >= 0,
      reading.courseAccuracyDegrees <= 30, reading.horizontalAccuracyMeters.isFinite,
      reading.horizontalAccuracyMeters >= 0, reading.horizontalAccuracyMeters <= 50
    else { return reject(.unreliable) }

    if let previousTimestamp, reading.timestamp <= previousTimestamp {
      smoother.reset()
    }
    let sample = CompassSample(
      degrees: reading.courseDegrees, source: .vehicleCourse, reference: .trueNorth,
      accuracyDegrees: reading.courseAccuracyDegrees, timestamp: reading.timestamp)
    let smoothed = smoother.update(sample, now: now, maximumAge: 5)
    previousTimestamp = reading.timestamp
    return TravelPresentation(sample: smoothed, status: .usable)
  }

  private mutating func reject(_ status: TravelStatus) -> TravelPresentation {
    reset()
    return TravelPresentation(sample: nil, status: status)
  }
}
