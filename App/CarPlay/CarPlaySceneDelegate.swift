import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?
  private var compass: CarPlayCompassTemplate?
  private var updates: CarPlayTemplateUpdates?
  private var styleCheck: CarPlayStyleCheck?
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
    styleCheck?.resign()
    styleCheck = CarPlayStyleCheck { [weak self] in self?.refreshStyle() }
    self.updates?.stop()
    let updates = CarPlayTemplateUpdates(drive: coordinator) { [weak self] next in
      self?.render(next)
    }
    self.updates = updates
    updates.update()
    interfaceController.setRootTemplate(screen.template, animated: false, completion: nil)
    // The template draws only what the updates read from the drive, so following those values
    // covers every change; course still shows in ten-second slots. Their first value makes a
    // second pass, now that the template is shown.
    updates.start()
    // Connection itself is not activation; use UISceneDelegate's foreground callback.
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    sceneActive = true
    styleCheck?.activate()
    observeDiagnostics()
    bridge?.activate()
  }
  func sceneWillResignActive(_ scene: UIScene) {
    sceneActive = false
    styleCheck?.resign()
    observeDiagnostics()
    bridge?.resign()
  }
  func sceneDidDisconnect(_ scene: UIScene) { disconnect() }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) { disconnect() }

  /// Apple doesn't say whether the car's trait collection has changed by the time this arrives,
  /// so the style is checked on a later turn. The content style it reports isn't the trait
  /// collection's style, and changes without it are left to the style check's interval.
  func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
    Task { [weak self] in self?.styleCheck?.check() }
  }

  private func disconnect() {
    sceneActive = false
    observeDiagnostics()
    bridge?.disconnect()
    bridge = nil
    updates?.stop()
    updates = nil
    styleCheck?.resign()
    styleCheck = nil
    compass = nil
    interfaceController = nil
    drive = nil
  }

  private func render(_ next: CarPlayPresentation?) {
    guard drive != nil, let compass, let interfaceController else { return }
    observeDiagnostics()
    if let next {
      compass.update(next, traits: interfaceController.carTraitCollection)
      _ = try? CompassDiagnostics.shared?.record(.fullscreen, kind: .templateUpdated)
    }
    // After a new value, this finds the style it was just drawn in and only restarts the wait
    // before the next check of its own.
    styleCheck?.check()
  }

  /// Redraws the current content when the car's style or scale differs from what it was drawn for.
  private func refreshStyle() {
    guard let compass, let interfaceController else { return }
    compass.refresh(traits: interfaceController.carTraitCollection)
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
