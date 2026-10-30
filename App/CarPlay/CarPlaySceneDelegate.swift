import CarPlay
import Combine
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?
  private var information: CPInformationTemplate?
  private var subscriptions: Set<AnyCancellable> = []
  private var ticker: Task<Void, Never>?
  private var latest: CarPlayPresentation?
  private var lastBearingUpdate = Date.distantPast
  private var bridge: CarPlayLifecycleBridge?
  private var drive: DriveSessionController?
  private var sceneActive = false

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    let coordinator = CompassAppDelegate.sharedDrive
    drive = coordinator
    bridge = CarPlayLifecycleBridge(drive: coordinator)
    self.interfaceController = interfaceController
    let template = CPInformationTemplate(title: "Compass", layout: .leading, items: [], actions: [])
    information = template
    interfaceController.setRootTemplate(template, animated: false, completion: nil)
    coordinator.objectWillChange.sink { [weak self] in
      Task { @MainActor in self?.render() }
    }.store(in: &subscriptions)
    render()
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        self?.render()
      }
    }
    // Connection itself is not activation; use UISceneDelegate's foreground callback.
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    sceneActive = true
    try? CompassDiagnostics.shared?.observe(.fullscreen, active: drive?.isDriving == true)
    bridge?.activate()
  }
  func sceneWillResignActive(_ scene: UIScene) {
    sceneActive = false
    try? CompassDiagnostics.shared?.observe(.fullscreen, active: false)
    bridge?.resign()
  }
  func sceneDidDisconnect(_ scene: UIScene) { disconnect() }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) { disconnect() }

  private func disconnect() {
    sceneActive = false
    try? CompassDiagnostics.shared?.observe(.fullscreen, active: false)
    bridge?.disconnect()
    bridge = nil
    ticker?.cancel()
    ticker = nil
    subscriptions.removeAll()
    information = nil
    interfaceController = nil
    drive = nil
    latest = nil
  }

  private func render() {
    guard let drive, let information else { return }
    try? CompassDiagnostics.shared?.observe(.fullscreen, active: sceneActive && drive.isDriving)
    let now = Date()
    let value = CarPlayPresentation(
      presentation: drive.presentation, setup: drive.setupStatus,
      driving: drive.isDriving, compact: drive.compactStatus, now: now)
    guard value != latest else { return }
    // Bearing-free invalidation bypasses the usable-bearing rate ceiling.
    if value.bearing != "—", now.timeIntervalSince(lastBearingUpdate) < 10 {
      return
    }
    latest = value
    if value.bearing != "—" { lastBearingUpdate = now }
    information.items = [
      CPInformationItem(title: value.reference, detail: value.bearing),
      CPInformationItem(title: "Status", detail: value.status),
      CPInformationItem(title: "Dashboard", detail: value.compact),
    ]
    _ = try? CompassDiagnostics.shared?.record(.fullscreen, kind: .templateUpdated)
    information.actions =
      value.canEndDrive
      ? [
        CPTextButton(title: "End Drive", textStyle: .cancel) { [weak self] _ in self?.bridge?.end()
        }
      ] : []
  }
}
