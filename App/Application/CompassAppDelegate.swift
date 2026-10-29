import CarPlay
import UIKit
import WidgetKit
import OSLog

@MainActor
final class CompassAppDelegate: NSObject, UIApplicationDelegate {
  // One process-lifetime owner shared by the phone and all CarPlay callbacks.
  static let sharedDrive = DriveSessionController(
    sensor: DeviceTravelLocationSensor(), activity: CompassActivityController(),
    reloadWidget: requestWidgetReload)

  private static let widgetLog = Logger(
    subsystem: "dev.lunchbox-labs.carplay-compass", category: "WidgetRefreshProbe")
  private static var widgetRequests = 0

  private static func requestWidgetReload(reason: String) {
    widgetRequests += 1
    widgetLog.info(
      "request #\(widgetRequests) at \(Date().timeIntervalSince1970) reason=\(reason, privacy: .public)"
    )
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
