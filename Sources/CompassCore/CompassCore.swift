import Foundation

/// A finite clockwise angle normalized into the half-open range 0..<360 degrees.
public struct CompassAngle: Sendable, Equatable {
  /// The normalized angle in degrees.
  public let degrees: Double

  /// Creates an angle, rejecting nonfinite input.
  public init?(degrees: Double) {
    guard degrees.isFinite else { return nil }
    let remainder = degrees.truncatingRemainder(dividingBy: 360)
    let normalized = remainder < 0 ? remainder + 360 : remainder
    self.degrees = normalized == 360 ? 0 : normalized
  }

  /// Returns the shortest signed rotation to another angle; exact half-turns are +180.
  public func shortestDelta(to other: Self) -> Double {
    let delta = other.degrees - degrees
    if delta <= -180 { return delta + 360 }
    if delta > 180 { return delta - 360 }
    return delta
  }
}

/// The physical quantity represented by a compass sample.
public enum CompassSource: Sendable, Equatable {
  /// The orientation of the device.
  case deviceHeading
  /// The vehicle's direction of travel, which is distinct from device orientation.
  case vehicleCourse
}

/// The north reference used by a sample.
public enum NorthReference: Sendable, Equatable {
  /// Magnetic north.
  case magnetic
  /// Geographic true north.
  case trueNorth
}

/// A validated sensor reading retaining its source, north reference, and measurement metadata.
public struct CompassSample: Sendable, Equatable {
  /// The measured or smoothed direction.
  public let angle: CompassAngle
  /// The physical source of the direction.
  public let source: CompassSource
  /// The north reference used for the direction.
  public let reference: NorthReference
  /// The nonnegative sensor uncertainty in degrees.
  public let accuracy: Double
  /// The sensor acquisition time.
  public let timestamp: Date

  /// Creates a sensor sample, rejecting sentinel angles, invalid accuracy, and invalid timestamps.
  ///
  /// Sensor angles must lie in 0...360; 360 is normalized to zero. Negative values are
  /// treated as unavailable sensor sentinels rather than normalized directions.
  public init?(
    degrees: Double, source: CompassSource, reference: NorthReference,
    accuracy: Double, timestamp: Date
  ) {
    guard degrees >= 0, degrees <= 360, let angle = CompassAngle(degrees: degrees),
      accuracy.isFinite, accuracy >= 0, timestamp.timeIntervalSince1970.isFinite
    else { return nil }
    self.angle = angle
    self.source = source
    self.reference = reference
    self.accuracy = accuracy
    self.timestamp = timestamp
  }

  private init(angle: CompassAngle, sample: Self) {
    self.angle = angle
    source = sample.source
    reference = sample.reference
    accuracy = sample.accuracy
    timestamp = sample.timestamp
  }

  /// Returns whether the sample is no older than the inclusive maximum age and is not future-dated.
  ///
  /// Both the supplied clock and maximum age must be finite; maximum age must be nonnegative.
  public func isFresh(now: Date, maximumAge: TimeInterval) -> Bool {
    guard now.timeIntervalSince1970.isFinite, maximumAge.isFinite, maximumAge >= 0 else {
      return false
    }
    let age = now.timeIntervalSince(timestamp)
    return age >= 0 && age <= maximumAge
  }

  fileprivate func replacingAngle(_ angle: CompassAngle) -> Self {
    Self(angle: angle, sample: self)
  }
}

/// A circular exponential smoother that retains metadata and resets across incompatible input.
public struct CompassSmoother: Sendable {
  private let fraction: Double
  private let fullTrackingDelta: Double?
  private var previous: CompassSample?

  /// Creates a smoother with a finite interpolation fraction in (0, 1].
  ///
  /// With a positive finite `fullTrackingDelta`, the interpolation fraction grows with the
  /// size of the shortest rotation to the new reading and reaches 1 at that many degrees, so
  /// turns are followed promptly while small changes are still damped by at least `fraction`.
  public init?(fraction: Double, fullTrackingDelta: Double? = nil) {
    guard fraction.isFinite, fraction > 0, fraction <= 1 else { return nil }
    if let fullTrackingDelta, !(fullTrackingDelta.isFinite && fullTrackingDelta > 0) {
      return nil
    }
    self.fraction = fraction
    self.fullTrackingDelta = fullTrackingDelta
  }

  /// Discards accumulated smoothing state.
  public mutating func reset() {
    previous = nil
  }

  /// Accepts a fresh sample, returning a smoothed sample with the new reading's metadata.
  ///
  /// Missing or stale input clears state and returns nil. Source/reference changes,
  /// stale previous readings, and reversed timestamps begin a new smoothing sequence.
  public mutating func update(
    _ sample: CompassSample?, now: Date,
    maximumAge: TimeInterval
  ) -> CompassSample? {
    guard let sample, sample.isFresh(now: now, maximumAge: maximumAge) else {
      reset()
      return nil
    }
    var result = sample
    if let previous, previous.source == sample.source, previous.reference == sample.reference,
      previous.isFresh(now: now, maximumAge: maximumAge),
      sample.timestamp >= previous.timestamp
    {
      let delta = previous.angle.shortestDelta(to: sample.angle)
      let weight = fullTrackingDelta.map { max(fraction, min(1, abs(delta) / $0)) } ?? fraction
      if let angle = CompassAngle(degrees: previous.angle.degrees + delta * weight) {
        result = sample.replacingAngle(angle)
      }
    }
    previous = result
    return result
  }
}
