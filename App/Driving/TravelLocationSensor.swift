import CompassCore
import CoreLocation
import Foundation

/// Authorization needed for foreground-created, When In Use travel acquisition.
enum TravelAuthorization { case notDetermined, authorized, denied, restricted }
enum TravelSensorEvent {
  case reading(TravelReading)
  case authorizationChanged
  case authorizationLost
  case interrupted
}

@MainActor
protocol TravelLocationSensor: AnyObject {
  var authorization: TravelAuthorization { get }
  var fullAccuracy: Bool { get }
  var available: Bool { get }
  var receive: ((TravelSensorEvent) -> Void)? { get set }
  func requestAuthorization()
  func start() throws
  func stop()
}

/// Each drive gets its own manager so delayed delegate deliveries cannot cross drives.
@MainActor
final class DeviceTravelLocationSensor: NSObject, TravelLocationSensor,
  @preconcurrency CLLocationManagerDelegate
{
  private let authorizationManager = CLLocationManager()
  private var manager: CLLocationManager?
  private var backgroundSession: CLBackgroundActivitySession?
  var receive: ((TravelSensorEvent) -> Void)?

  override init() {
    super.init()
    authorizationManager.delegate = self
  }

  var authorization: TravelAuthorization {
    switch authorizationManager.authorizationStatus {
    case .notDetermined: .notDetermined
    case .authorizedAlways, .authorizedWhenInUse: .authorized
    case .restricted: .restricted
    default: .denied
    }
  }
  var fullAccuracy: Bool { authorizationManager.accuracyAuthorization == .fullAccuracy }
  var available: Bool {
    CLLocationManager.locationServicesEnabled()
      && (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
        .contains("location") == true
      && !(Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription")
        as? String ?? "").isEmpty
  }

  isolated deinit {
    manager?.stopUpdatingLocation()
    backgroundSession?.invalidate()
  }

  func requestAuthorization() { authorizationManager.requestWhenInUseAuthorization() }

  enum StartError: Error { case unavailable }
  func start() throws {
    guard manager == nil else { return }
    guard available, authorization == .authorized, fullAccuracy else {
      throw StartError.unavailable
    }
    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.activityType = .automotiveNavigation
    manager.distanceFilter = kCLDistanceFilterNone
    manager.pausesLocationUpdatesAutomatically = false
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = true
    // The caller revalidates active CarPlay eligibility immediately before this call.
    backgroundSession = CLBackgroundActivitySession()
    self.manager = manager
    manager.startUpdatingLocation()
  }

  func stop() {
    manager?.stopUpdatingLocation()
    manager?.allowsBackgroundLocationUpdates = false
    manager?.delegate = nil
    manager = nil
    backgroundSession?.invalidate()
    backgroundSession = nil
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard manager === authorizationManager || manager === self.manager else { return }
    receive?(.authorizationChanged)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard manager === self.manager, let location = locations.last else { return }
    // Position is never copied, retained, or passed to the presentation layer.
    receive?(
      .reading(
        TravelReading(
          course: location.course, courseAccuracy: location.courseAccuracy,
          speed: location.speed, speedAccuracy: location.speedAccuracy,
          horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp)))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard manager === self.manager else { return }
    if (error as? CLError)?.code == .denied {
      receive?(.authorizationLost)
    } else {
      receive?(.interrupted)
    }
  }
}
