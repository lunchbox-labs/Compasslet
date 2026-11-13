import CoreLocation
@testable import Compass

/// Travel location whose access a test sets, recording what the drive asks of it.
@MainActor
final class TestTravelSensor: TravelLocationSensor {
  enum Failure: Error { case unavailable }

  var authorization: TravelAuthorization
  var fullAccuracy: Bool
  var servicesEnabled: Bool
  var available: Bool
  var receive: ((TravelSensorEvent) -> Void)?
  /// Whether `requestAuthorization()` also asks the system while access is undecided, so the
  /// simulator shows its prompt.
  var showsSystemPrompt: Bool
  /// Makes `start()` throw instead of starting.
  var fails = false
  var requests = 0
  var starts = 0
  var stops = 0
  private var permissionManager: CLLocationManager?

  init(
    authorization: TravelAuthorization = .authorized, fullAccuracy: Bool = true,
    servicesEnabled: Bool = true, available: Bool = true, showsSystemPrompt: Bool = false
  ) {
    self.authorization = authorization
    self.fullAccuracy = fullAccuracy
    self.servicesEnabled = servicesEnabled
    self.available = available
    self.showsSystemPrompt = showsSystemPrompt
  }

  func requestAuthorization() {
    requests += 1
    guard showsSystemPrompt, authorization == .notDetermined else { return }
    let manager = CLLocationManager()
    permissionManager = manager
    manager.requestWhenInUseAuthorization()
  }

  func start() throws {
    if fails { throw Failure.unavailable }
    starts += 1
  }

  func stop() { stops += 1 }
}
