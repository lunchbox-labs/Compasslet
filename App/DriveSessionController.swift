import Combine
import CompassCore
import Foundation

@MainActor
final class DriveSessionController: ObservableObject {
  enum SetupStatus { case ready, permissionRequired, preciseLocationRequired, unavailable }
  enum CompactStatus { case inactive, starting, active, unavailable, dismissed }
  @Published private(set) var presentation = TravelPresentation(sample: nil, status: .unavailable)
  @Published private(set) var isDriving = false
  @Published private(set) var setupStatus: SetupStatus = .ready
  @Published private(set) var compactStatus: CompactStatus = .inactive

  private let sensor: any TravelLocationSensor
  private let activity: any CompassActivityPresenting
  private let now: () -> Date
  private let automaticTick: Bool
  private var filter = TravelCourseFilter()
  private var lastReading: TravelReading?
  private var startedAt: Date?
  private var generation = UUID()
  private var active = false
  private var suppressed = false
  private var requestedPermission = false
  private var preparation: Task<Void, Never>?
  private var activityOperation: Task<Void, Never>?
  private var ticker: Task<Void, Never>?
  private var pendingPresentation: TravelPresentation?
  private var drainGeneration: UUID?

  init(
    sensor: any TravelLocationSensor, activity: any CompassActivityPresenting,
    now: @escaping () -> Date = Date.init, automaticTick: Bool = true
  ) {
    self.sensor = sensor
    self.activity = activity
    self.now = now
    self.automaticTick = automaticTick
    refreshSetupStatus()
    observeAuthorization()
  }

  isolated deinit {
    ticker?.cancel()
    sensor.stop()
  }

  /// Called on ordinary phone launch to clear surviving activity state, never to acquire location.
  func prepare() async {
    if let preparation { await preparation.value; return }
    let operation = enqueue { [activity] in await activity.end() }
    preparation = operation
    await operation.value
  }

  func requestPhoneAuthorization(isForeground: Bool) {
    guard isForeground, !requestedPermission, sensor.authorization == .notDetermined else { return }
    requestedPermission = true
    sensor.requestAuthorization()
    refreshSetupStatus()
  }

  func carPlayActivated() async {
    active = true
    await prepare()
    refreshSetupStatus()
    guard active, !suppressed, !isDriving, setupStatus == .ready else { return }
    let token = UUID()
    generation = token
    sensor.receive = { [weak self] event in self?.receive(event, generation: token) }
    do { try sensor.start() } catch {
      sensor.stop()
      sensor.receive = nil
      setupStatus = .unavailable
      return
    }
    isDriving = true
    startedAt = now()
    filter.reset()
    lastReading = nil
    presentation = TravelPresentation(sample: nil, status: .waiting)
    compactStatus = .starting
    startTicker()
    let operation = enqueue { [weak self, activity] in
      guard let self, self.isDriving, self.generation == token else { return }
      activity.onDismiss = { [weak self] in
        guard let self, self.isDriving, self.generation == token else { return }
        self.suppressed = true
        _ = self.stopDrive()
        self.compactStatus = .dismissed
      }
      do {
        try await activity.start()
        guard self.isDriving, self.generation == token else { return }
        self.compactStatus = .active
        await activity.update(self.presentation)
      } catch {
        guard self.isDriving, self.generation == token else { return }
        self.compactStatus = .unavailable
      }
    }
    await operation.value
  }

  func carPlayResignedActive() {
    active = false
    suppressed = false
  }

  func carPlayDisconnected() async {
    active = false
    suppressed = false
    await stopDrive()?.value
  }

  func endDrive() async {
    suppressed = true
    await stopDrive()?.value
  }

  func tick() {
    guard isDriving, let startedAt else { return }
    refreshSetupStatus()
    let elapsed = now().timeIntervalSince(startedAt)
    guard setupStatus == .ready, elapsed.isFinite, elapsed >= 0, elapsed < 8 * 60 * 60 else {
      _ = stopDrive()
      return
    }
    if let lastReading,
      !(0...5).contains(now().timeIntervalSince(lastReading.timestamp))
    {
      publish(filter.update(nil, now: now()))
      self.lastReading = nil
    }
  }

  func waitForPendingOperations() async { await activityOperation?.value }

  private func observeAuthorization() {
    sensor.receive = { [weak self] event in
      if case .authorizationChanged = event { self?.refreshSetupStatus() }
    }
  }

  private func refreshSetupStatus() {
    if !sensor.available {
      setupStatus = .unavailable
    } else if sensor.authorization != .authorized {
      setupStatus = .permissionRequired
    } else if !sensor.fullAccuracy {
      setupStatus = .preciseLocationRequired
    } else {
      setupStatus = .ready
    }
  }

  private func receive(_ event: TravelSensorEvent, generation token: UUID) {
    guard isDriving, token == generation else { return }
    refreshSetupStatus()
    guard setupStatus == .ready else { _ = stopDrive(); return }
    switch event {
    case .authorizationChanged: break
    case .authorizationLost:
      setupStatus = .permissionRequired
      _ = stopDrive()
    case .interrupted:
      lastReading = nil
      publish(filter.update(nil, now: now()))
    case .reading(let reading):
      lastReading = reading
      publish(filter.update(reading, now: now()))
    }
  }

  private func publish(_ value: TravelPresentation) {
    presentation = value
    pendingPresentation = value
    let token = generation
    guard drainGeneration != token else { return }
    drainGeneration = token
    _ = enqueue { [weak self, activity] in
      guard let self else { return }
      while self.isDriving, self.generation == token, self.compactStatus == .active,
        let latest = self.pendingPresentation
      {
        self.pendingPresentation = nil
        await activity.update(latest)
      }
      if self.drainGeneration == token {
        self.pendingPresentation = nil
        self.drainGeneration = nil
      }
    }
  }

  @discardableResult
  private func stopDrive() -> Task<Void, Never>? {
    guard isDriving else { return nil }
    generation = UUID()
    pendingPresentation = nil
    drainGeneration = nil
    isDriving = false
    ticker?.cancel()
    ticker = nil
    sensor.stop()
    observeAuthorization()
    startedAt = nil
    lastReading = nil
    filter.reset()
    presentation = TravelPresentation(sample: nil, status: .unavailable)
    compactStatus = .inactive
    return enqueue { [activity] in
      activity.onDismiss = nil
      await activity.end()
    }
  }

  private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let previous = activityOperation
    let task = Task { @MainActor in
      await previous?.value
      await operation()
    }
    activityOperation = task
    return task
  }

  private func startTicker() {
    guard automaticTick else { return }
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        self?.tick()
      }
    }
  }
}
