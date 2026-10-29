import CarPlay
import UIKit
import WidgetKit

@MainActor
final class CompassAppDelegate: NSObject, UIApplicationDelegate {
  // One process-lifetime owner shared by the phone and all CarPlay callbacks.
  static let sharedDrive = DriveSessionController(
    sensor: DeviceTravelLocationSensor(), activity: CompassActivityController(),
    reloadWidget: requestWidgetReload)

  private static func requestWidgetReload(reason: String) {
    try? CompassDiagnostics.shared?.record(.widget, kind: .reloadRequested)
    WidgetCenter.shared.reloadTimelines(ofKind: "CompassRefreshProbe")
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
