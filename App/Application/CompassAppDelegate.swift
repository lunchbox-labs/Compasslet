import CarPlay
import UIKit

@MainActor
final class CompassAppDelegate: NSObject, UIApplicationDelegate {
  // One process-lifetime owner shared by the phone and all CarPlay callbacks.
  static let sharedDrive: DriveSessionController = {
    if let directory = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: AppearanceStore.suiteName)
    {
      try? RetiredWidgetData.remove(from: directory)
    }
    let drive = DriveSessionController(
      sensor: DeviceTravelLocationSensor(), activity: CompassActivityController(),
      carAudioRoute: { CarAudioRouteMonitor.isConnected },
      backgroundTime: { holdBackgroundTime() })
    carAudio = CarAudioRouteMonitor { [weak drive] connected in
      drive?.carAudioChanged(connected: connected)
    }
    return drive
  }()
  private static var carAudio: CarAudioRouteMonitor?

  /// Asks iOS for time to finish work in the background, and returns what gives it back.
  private static func holdBackgroundTime() -> @MainActor () -> Void {
    let time = BackgroundTime()
    time.identifier = UIApplication.shared.beginBackgroundTask(withName: "Drive") {
      MainActor.assumeIsolated { time.end() }
    }
    return { time.end() }
  }

  @MainActor private final class BackgroundTime {
    var identifier = UIBackgroundTaskIdentifier.invalid
    func end() {
      guard identifier != .invalid else { return }
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
  }

  var drive: DriveSessionController { Self.sharedDrive }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    if connectingSceneSession.role == .carTemplateApplication {
      let configuration = UISceneConfiguration(
        name: "CarPlay", sessionRole: connectingSceneSession.role)
      configuration.sceneClass = CPTemplateApplicationScene.self
      configuration.delegateClass = CarPlaySceneDelegate.self
      return configuration
    }
    return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
  }
}
