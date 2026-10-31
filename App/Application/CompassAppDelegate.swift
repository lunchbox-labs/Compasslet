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
    return DriveSessionController(
      sensor: DeviceTravelLocationSensor(), activity: CompassActivityController())
  }()

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
