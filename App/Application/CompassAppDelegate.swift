import CarPlay
import UIKit
import WidgetKit

@MainActor
final class CompassAppDelegate: NSObject, UIApplicationDelegate {
  // One process-lifetime owner shared by the phone and all CarPlay callbacks.
  static let sharedDrive: DriveSessionController = {
    // Clear a surviving file once per app process, never on ordinary foreground transitions.
    writeWidgetSnapshot(.unavailable(at: Date()))
    requestWidgetReload(reason: "app initialized")
    return DriveSessionController(
      sensor: DeviceTravelLocationSensor(), activity: CompassActivityController(),
      reloadWidget: requestWidgetReload, writeWidget: writeWidgetSnapshot)
  }()

  private static func writeWidgetSnapshot(_ snapshot: LatestCourseSnapshot) {
    guard let store = LatestCourseStore.shared else { return }
    do { try store.write(snapshot, now: Date()) } catch {
      // If replacement fails, do not intentionally retain an earlier usable reading.
      try? FileManager.default.removeItem(at: store.url)
    }
  }

  private static func requestWidgetReload(reason: String) {
    _ = try? CompassDiagnostics.shared?.record(.widget, kind: .reloadRequested)
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
