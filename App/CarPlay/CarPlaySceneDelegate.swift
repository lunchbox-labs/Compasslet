import CarPlay
import Combine
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?
  private var compass: CarPlayCompassTemplate?
  private var subscriptions: Set<AnyCancellable> = []
  private var ticker: Task<Void, Never>?
  private var updates = CarPlayUpdateGate()
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
    CarPlayDisplayInfo.record(interfaceController.carTraitCollection)
    let screen = CarPlayCompassTemplate()
    compass = screen
    updates = CarPlayUpdateGate()
    render()
    interfaceController.setRootTemplate(screen.template, animated: false, completion: nil)
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
    compass = nil
    interfaceController = nil
    drive = nil
    updates = CarPlayUpdateGate()
  }

  private func render() {
    guard let drive, let compass, let interfaceController else { return }
    try? CompassDiagnostics.shared?.observe(.fullscreen, active: sceneActive && drive.isDriving)
    compass.refresh(traits: interfaceController.carTraitCollection)
    let now = Date()
    let value = CarPlayPresentation(
      presentation: drive.presentation, setup: drive.setupStatus,
      driving: drive.isDriving, now: now)
    guard let next = updates.update(value, now: now) else { return }
    compass.update(next, traits: interfaceController.carTraitCollection)
    _ = try? CompassDiagnostics.shared?.record(.fullscreen, kind: .templateUpdated)
  }
}
