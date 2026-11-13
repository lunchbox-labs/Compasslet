import CoreLocation
@testable import Compass

/// A phone location sensor that records its starts and stops. Given a fix, it repeats that fix,
/// fresh each time, while it runs, so the fix never goes stale.
@MainActor
final class TestPhoneLocationSensor: PhoneLocationSensor {
  /// Where the sensor reports the phone to be, dated when each fix is sent.
  struct Fix {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double

    /// A precise fix at Apple Park.
    static let applePark = Fix(
      latitude: 37.3349, longitude: -122.009, altitude: 48, horizontalAccuracy: 5,
      verticalAccuracy: 3)

    func location(at timestamp: Date) -> CLLocation {
      CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
        altitude: altitude, horizontalAccuracy: horizontalAccuracy,
        verticalAccuracy: verticalAccuracy, timestamp: timestamp)
    }
  }

  var authorized: Bool
  var precise = true
  var servicesEnabled = true
  var receive: ((PhoneLocationEvent) -> Void)?
  /// The fix repeated while the sensor runs, or nil to leave fixes to the test.
  let fix: Fix?
  var starts = 0
  var stops = 0
  private var repeating: Task<Void, Never>?

  init(authorized: Bool = true, fix: Fix? = nil) {
    self.authorized = authorized
    self.fix = fix
  }

  func start() {
    starts += 1
    guard let fix else { return }
    repeating = Task { [weak self] in
      while !Task.isCancelled {
        self?.receive?(.location(fix.location(at: .now)))
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func stop() {
    stops += 1
    repeating?.cancel()
    repeating = nil
  }
}
