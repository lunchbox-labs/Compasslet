import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?
  private var compass: CarPlayCompassTemplate?
  private var updates: CarPlayTemplateUpdates?
  private var bridge: CarPlayLifecycleBridge?
  private var drive: DriveSessionController?
  private var sceneActive = false
  /// The next full-screen diagnostics observation between template passes.
  private var diagnosticsTick: Task<Void, Never>?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    let coordinator = CompassAppDelegate.sharedDrive
    drive = coordinator
    coordinator.carPlayConnected()
    bridge = CarPlayLifecycleBridge(drive: coordinator)
    self.interfaceController = interfaceController
    CarPlayDisplayInfo.record(interfaceController.carTraitCollection)
    let screen = CarPlayCompassTemplate()
    compass = screen
    self.updates?.stop()
    let updates = CarPlayTemplateUpdates(drive: coordinator) { [weak self] next in
      self?.render(next)
    }
    self.updates = updates
    updates.update()
    interfaceController.setRootTemplate(screen.template, animated: false, completion: nil)
    // The template draws only what the updates read from the drive, so following those values
    // covers every change; course still shows in ten-second slots.
    updates.start()
    // Connection itself is not activation; use UISceneDelegate's foreground callback.
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    sceneActive = true
    observeDiagnostics()
    bridge?.activate()
  }
  func sceneWillResignActive(_ scene: UIScene) {
    sceneActive = false
    observeDiagnostics()
    bridge?.resign()
  }
  func sceneDidDisconnect(_ scene: UIScene) { disconnect() }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) { disconnect() }

  /// The car's light or dark style arrives through its trait collection, not the drive.
  func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
    guard let compass, let interfaceController else { return }
    compass.refresh(traits: interfaceController.carTraitCollection)
  }

  private func disconnect() {
    sceneActive = false
    observeDiagnostics()
    bridge?.disconnect()
    bridge = nil
    updates?.stop()
    updates = nil
    compass = nil
    interfaceController = nil
    drive = nil
  }

  private func render(_ next: CarPlayPresentation?) {
    guard drive != nil, let compass, let interfaceController else { return }
    observeDiagnostics()
    compass.refresh(traits: interfaceController.carTraitCollection)
    guard let next else { return }
    compass.update(next, traits: interfaceController.carTraitCollection)
    _ = try? CompassDiagnostics.shared?.record(.fullscreen, kind: .templateUpdated)
  }

  /// Observes whether a drive shows on the active scene. Diagnostics count a gap over 2 seconds
  /// as a new session, and passes come only with changes, so while one shows with Debug Mode on,
  /// this observes again a second later, through stretches with nothing new to show.
  private func observeDiagnostics() {
    let active = sceneActive && drive?.isDriving == true
    try? CompassDiagnostics.shared?.observe(.fullscreen, active: active)
    guard active, CompassDiagnostics.shared?.isEnabled == true else {
      diagnosticsTick?.cancel()
      diagnosticsTick = nil
      return
    }
    guard diagnosticsTick == nil else { return }
    diagnosticsTick = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.diagnosticsTick = nil
      self.observeDiagnostics()
    }
  }
}
