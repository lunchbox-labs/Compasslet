import Foundation
@testable import Compass

/// A heading sensor that records its starts and stops. Given a reading, it repeats that reading,
/// fresh each time, while it runs.
@MainActor
final class TestHeadingSensor: HeadingSensor {
  struct Reading {
    let degrees: Double
    let accuracy: Double

    static let northeast = Reading(degrees: 47, accuracy: 5)
    /// Core Location reports a negative accuracy when the compass needs calibration.
    static let calibrationNeeded = Reading(degrees: 47, accuracy: -1)
  }

  var available: Bool
  var receive: ((HeadingEvent) -> Void)?
  /// The reading repeated while the sensor runs, or nil to leave readings to the test.
  let reading: Reading?
  var starts = 0
  var stops = 0
  private var repeating: Task<Void, Never>?

  init(available: Bool = true, reading: Reading? = nil) {
    self.available = available
    self.reading = reading
  }

  func start() {
    starts += 1
    guard let reading else { return }
    repeating = Task { [weak self] in
      while !Task.isCancelled {
        self?.receive?(
          .reading(degrees: reading.degrees, accuracy: reading.accuracy, timestamp: .now))
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  func stop() {
    stops += 1
    repeating?.cancel()
    repeating = nil
  }
}
