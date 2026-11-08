import CoreLocation
import Foundation
import MapKit
import Observation

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
  /// Made on first use, when the controller starts and reads authorization, so a sensor that
  /// never starts, such as one a view builds and discards, allocates no manager.
  private lazy var authorizationManager: CLLocationManager = {
    let manager = CLLocationManager()
    manager.delegate = self
    return manager
  }()
  private var manager: CLLocationManager?
  var receive: ((PhoneLocationEvent) -> Void)?

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
protocol PhoneCityLookup: AnyObject {
  func lookup(_ location: CLLocation, completion: @escaping @MainActor (String?) -> Void)
  func cancel()
}

@MainActor
final class ApplePhoneCityLookup: PhoneCityLookup {
  private var request: MKReverseGeocodingRequest?
  private var task: Task<Void, Never>?

  func lookup(_ location: CLLocation, completion: @escaping @MainActor (String?) -> Void) {
    cancel()
    guard let request = MKReverseGeocodingRequest(location: location) else {
      completion(nil)
      return
    }
    request.preferredLocale = .current
    self.request = request
    task = Task {
      let items = try? await request.mapItems
      guard !Task.isCancelled else { return }
      completion(items?.first?.addressRepresentations?.cityWithContext)
    }
  }

  func cancel() {
    task?.cancel()
    request?.cancel()
    task = nil
    request = nil
  }

  isolated deinit {
    task?.cancel()
    request?.cancel()
  }
}

@MainActor @Observable
final class PhoneLocationController {
  private(set) var location: CLLocation?
  private(set) var approximate = false
  private(set) var city: String?
  private let cityLookup: any PhoneCityLookup
  @ObservationIgnored private var cityToken: UUID?
  @ObservationIgnored private var cityAnchor: CLLocation?
  @ObservationIgnored private var lastCityAttempt: Date?
  private let sensor: any PhoneLocationSensor
  private let now: () -> Date
  @ObservationIgnored private var active = false
  @ObservationIgnored private var acquiring = false
  @ObservationIgnored private var session: UUID?

  init(
    sensor: any PhoneLocationSensor = DevicePhoneLocationSensor(),
    cityLookup: any PhoneCityLookup = ApplePhoneCityLookup(),
    now: @escaping () -> Date = Date.init
  ) {
    self.sensor = sensor
    self.cityLookup = cityLookup
    self.now = now
    sensor.receive = { [weak self] event in self?.receive(event) }
  }

  isolated deinit {
    sensor.stop()
    cityLookup.cancel()
  }

  var elevation: Double? {
    guard let location, location.altitude.isFinite,
      location.verticalAccuracy.isFinite, location.verticalAccuracy > 0,
      location.verticalAccuracy <= 50
    else { return nil }
    return location.altitude
  }

  func start() {
    clearLocation()
    active = true
    refreshAuthorization()
  }

  func stop(preservingLastReading: Bool = false) {
    if preservingLastReading { tick() }
    session = nil
    active = false
    if acquiring { sensor.stop() }
    acquiring = false
    cityToken = nil
    cityLookup.cancel()
    if !preservingLastReading {
      clearLocation()
      approximate = false
    }
  }

  func run(preservingLastReadingOnStop: Bool = false) async {
    guard !Task.isCancelled else { return }
    let token = UUID()
    session = token
    start()
    defer {
      if session == token { stop(preservingLastReading: preservingLastReadingOnStop) }
    }
    while !Task.isCancelled, session == token {
      tick()
      do { try await Task.sleep(for: .seconds(1)) } catch { break }
    }
  }

  func tick() {
    guard active else { return }
    refreshAuthorization()
    if let location, !(0...30).contains(now().timeIntervalSince(location.timestamp)) {
      clearLocation()
    }
  }

  private func refreshAuthorization() {
    let allowed = active && sensor.authorized && sensor.servicesEnabled
    approximate = allowed && !sensor.precise
    if !allowed || approximate { clearLocation() }
    if allowed && !acquiring {
      acquiring = true
      sensor.start()
    } else if !allowed && acquiring {
      acquiring = false
      sensor.stop()
    }
  }

  private func receive(_ event: PhoneLocationEvent) {
    guard active else {
      if case .authorizationChanged = event {
        approximate = sensor.authorized && sensor.servicesEnabled && !sensor.precise
        if !sensor.authorized || !sensor.servicesEnabled || !sensor.precise { clearLocation() }
      }
      return
    }
    refreshAuthorization()
    switch event {
    case .authorizationChanged: break
    case .unavailable: clearLocation()
    case .location(let fix):
      guard acquiring, !approximate, CLLocationCoordinate2DIsValid(fix.coordinate),
        fix.horizontalAccuracy.isFinite, (0...100).contains(fix.horizontalAccuracy),
        (0...30).contains(now().timeIntervalSince(fix.timestamp))
      else { clearLocation(); return }
      location = fix
      updateCity(for: fix)
    }
  }

  private func clearLocation() {
    location = nil
    city = nil
    cityAnchor = nil
    cityToken = nil
    cityLookup.cancel()
  }

  private func updateCity(for fix: CLLocation) {
    let moved = cityAnchor.map { fix.distance(from: $0) >= 500 } ?? true
    if moved {
      city = nil
      if cityToken != nil {
        cityToken = nil
        cityLookup.cancel()
      }
    }
    guard cityToken == nil else { return }
    let elapsed = lastCityAttempt.map { now().timeIntervalSince($0) } ?? .infinity
    guard elapsed >= 60, moved || city == nil || elapsed >= 600 else { return }
    let token = UUID()
    cityToken = token
    cityAnchor = fix
    lastCityAttempt = now()
    cityLookup.lookup(fix) { [weak self] city in
      guard let self, self.active, self.cityToken == token,
        let current = self.location, current.distance(from: fix) < 500
      else { return }
      self.cityToken = nil
      self.city = city
    }
  }

}
