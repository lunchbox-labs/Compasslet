import Combine
import CoreLocation
import Foundation

enum PhoneLocationEvent {
  case location(CLLocation), authorizationChanged, unavailable
}

@MainActor
protocol PhoneLocationSensor: AnyObject {
  var authorized: Bool { get }
  var precise: Bool { get }
  var servicesEnabled: Bool { get }
  var receive: ((PhoneLocationEvent) -> Void)? { get set }
  func start()
  func stop()
}

/// Foreground phone fixes never enter the driving pipeline or shared storage.
@MainActor
final class DevicePhoneLocationSensor: NSObject, PhoneLocationSensor,
  @preconcurrency CLLocationManagerDelegate
{
  private let authorizationManager = CLLocationManager()
  private var manager: CLLocationManager?
  var receive: ((PhoneLocationEvent) -> Void)?

  override init() {
    super.init()
    authorizationManager.delegate = self
  }

  var authorized: Bool {
    [.authorizedWhenInUse, .authorizedAlways].contains(authorizationManager.authorizationStatus)
  }
  var precise: Bool { authorizationManager.accuracyAuthorization == .fullAccuracy }
  var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

  func start() {
    guard manager == nil, authorized, servicesEnabled else { return }
    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.distanceFilter = kCLDistanceFilterNone
    self.manager = manager
    manager.startUpdatingLocation()
  }

  func stop() {
    manager?.stopUpdatingLocation()
    manager?.delegate = nil
    manager = nil
  }

  isolated deinit { manager?.stopUpdatingLocation() }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard manager === authorizationManager || manager === self.manager else { return }
    receive?(.authorizationChanged)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard manager === self.manager, let location = locations.last else { return }
    receive?(.location(location))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    guard manager === self.manager else { return }
    receive?(.unavailable)
  }
}

@MainActor
final class PhoneLocationController: ObservableObject {
  @Published private(set) var location: CLLocation?
  @Published private(set) var approximate = false
  private let sensor: any PhoneLocationSensor
  private let now: () -> Date
  private var active = false
  private var acquiring = false
  private var session: UUID?

  init(
    sensor: any PhoneLocationSensor = DevicePhoneLocationSensor(),
    now: @escaping () -> Date = Date.init
  ) {
    self.sensor = sensor
    self.now = now
    sensor.receive = { [weak self] event in self?.receive(event) }
  }

  isolated deinit { sensor.stop() }

  var elevation: Double? {
    guard let location, location.altitude.isFinite,
      location.verticalAccuracy.isFinite, location.verticalAccuracy > 0,
      location.verticalAccuracy <= 50
    else { return nil }
    return location.altitude
  }

  func start() {
    active = true
    refreshAuthorization()
  }

  func stop() {
    session = nil
    active = false
    if acquiring { sensor.stop() }
    acquiring = false
    location = nil
    approximate = false
  }

  func run() async {
    let token = UUID()
    session = token
    start()
    defer { if session == token { stop() } }
    while !Task.isCancelled, session == token {
      tick()
      do { try await Task.sleep(for: .seconds(1)) } catch { break }
    }
  }

  func tick() {
    guard active else { return }
    refreshAuthorization()
    if let location, !(0...30).contains(now().timeIntervalSince(location.timestamp)) {
      self.location = nil
    }
  }

  private func refreshAuthorization() {
    let allowed = active && sensor.authorized && sensor.servicesEnabled
    approximate = allowed && !sensor.precise
    if !allowed || approximate { location = nil }
    if allowed && !acquiring {
      acquiring = true
      sensor.start()
    } else if !allowed && acquiring {
      acquiring = false
      sensor.stop()
    }
  }

  private func receive(_ event: PhoneLocationEvent) {
    guard active else { return }
    refreshAuthorization()
    switch event {
    case .authorizationChanged: break
    case .unavailable: location = nil
    case .location(let fix):
      guard acquiring, !approximate, CLLocationCoordinate2DIsValid(fix.coordinate),
        fix.horizontalAccuracy.isFinite, (0...100).contains(fix.horizontalAccuracy),
        (0...30).contains(now().timeIntervalSince(fix.timestamp))
      else { location = nil; return }
      location = fix
    }
  }
}
