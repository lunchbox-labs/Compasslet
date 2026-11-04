import Combine
import CompassCore
import Foundation

@MainActor
final class DriveSessionController: ObservableObject {
  enum SetupStatus {
    case ready, permissionRequired, denied, restricted, servicesDisabled, preciseLocationRequired,
      unavailable
  }
  enum CompactStatus { case inactive, starting, active, unavailable, dismissed }
  @Published private(set) var presentation = TravelPresentation(sample: nil, status: .unavailable)
  @Published private(set) var isDriving = false
  @Published private(set) var setupStatus: SetupStatus = .ready
  @Published private(set) var compactStatus: CompactStatus = .inactive
  /// Whether Compasslet's CarPlay scene is connected, whether or not it's in front.
  @Published private(set) var isCarPlayConnected = false

  /// How long a drive keeps running without a connected CarPlay scene before it ends.
  static let carPlayAbsenceLimit: TimeInterval = 60

  private let sensor: any TravelLocationSensor
  private let activity: any CompassActivityPresenting
  private let now: () -> Date
  private let automaticTick: Bool
  private var filter = TravelCourseFilter()
  private var lastReading: TravelReading?
  private var startedAt: Date?
  private var carPlayAbsentSince: Date?
  private var generation = UUID()
  private var active = false
  private var suppressed = false
  private var requestedPermission = false
  private var preparation: Task<Void, Never>?
  private var activityOperation: Task<Void, Never>?
  private var ticker: Task<Void, Never>?
  private var pendingActivityInvalidation = false
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

  /// Refresh on return from Settings; permission alone never starts travel acquisition.
  func phoneBecameActive(requestingPermission: Bool = true) async {
    await prepare()
    guard !Task.isCancelled else { return }
    refreshSetupStatus()
    if setupStatus != .ready { _ = stopDrive() }
    // A failed phone start shouldn't keep asking for a setting the user has since changed.
    if !isDriving, compactStatus == .unavailable, activity.canStartActivities {
      compactStatus = .inactive
    }
    if requestingPermission { requestPhoneAuthorization(isForeground: true) }
  }

  func requestPhoneAuthorization(isForeground: Bool) {
    guard isForeground, !requestedPermission, setupStatus == .permissionRequired,
      sensor.authorization == .notDetermined
    else { return }
    requestedPermission = true
    sensor.requestAuthorization()
    refreshSetupStatus()
  }

  func carPlayConnected() {
    isCarPlayConnected = true
    carPlayAbsentSince = nil
  }

  func carPlayActivated() async {
    active = true
    carPlayConnected()
    await prepare()
    refreshSetupStatus()
    guard active, !suppressed, !isDriving else { return }
    guard setupStatus == .ready else {
      return
    }
    await beginDrive()
  }

  /// The manual fallback for when the automatic CarPlay start doesn't produce a Live Activity.
  /// With no drive running, it starts one. Started before CarPlay connects, as from Shortcuts,
  /// the drive ends unless CarPlay connects within the absence limit. During a drive whose Live
  /// Activity was dismissed or couldn't start, it starts only the Live Activity again. Call it
  /// from the foreground app, because ActivityKit only starts activities there.
  func startLiveActivity() async {
    await prepare()
    refreshSetupStatus()
    guard setupStatus == .ready else { return }
    guard isDriving else {
      // Without CarPlay the drive exists only for the Live Activity, so don't acquire
      // location when the system won't show one.
      guard isCarPlayConnected || activity.canStartActivities else {
        compactStatus = .unavailable
        return
      }
      await beginDrive()
      return
    }
    guard compactStatus == .dismissed || compactStatus == .unavailable else { return }
    compactStatus = .starting
    // A new activity has no retained reading to invalidate.
    pendingActivityInvalidation = false
    await startActivity(generation: generation).value
  }

  private func beginDrive() async {
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
    carPlayAbsentSince = isCarPlayConnected ? nil : startedAt
    filter.reset()
    lastReading = nil
    presentation = TravelPresentation(sample: nil, status: .waiting)
    compactStatus = .starting
    startTicker()
    await startActivity(generation: token).value
  }

  private func startActivity(generation token: UUID) -> Task<Void, Never> {
    enqueue { [weak self, activity] in
      guard let self, self.isDriving, self.generation == token else { return }
      activity.onDismiss = { [weak self] in
        guard let self, self.isDriving, self.generation == token else { return }
        // ActivityKit ends activities on its own, so during a CarPlay drive losing the
        // compact card only ends its updates until CarPlay disconnects or the user ends it.
        // Without CarPlay nothing else shows the drive, so it ends too.
        guard self.isCarPlayConnected else {
          _ = self.stopDrive()
          return
        }
        self.compactStatus = .dismissed
      }
      do {
        try await activity.start()
        guard self.isDriving, self.generation == token, self.compactStatus == .starting else {
          return
        }
        self.compactStatus = .active
        if self.pendingActivityInvalidation {
          self.pendingActivityInvalidation = false
          await activity.invalidateReading()
        }
        guard self.isDriving, self.generation == token, !self.pendingActivityInvalidation else {
          return
        }
        await activity.update(self.presentation)
      } catch {
        guard self.isDriving, self.generation == token else { return }
        guard self.isCarPlayConnected else {
          _ = self.stopDrive()
          self.compactStatus = .unavailable
          return
        }
        self.compactStatus = .unavailable
      }
    }
  }

  func carPlayResignedActive() {
    active = false
    suppressed = false
  }

  /// A brief disconnect keeps the drive; `tick` ends it once CarPlay stays away too long.
  func carPlayDisconnected() {
    active = false
    suppressed = false
    isCarPlayConnected = false
    if isDriving, carPlayAbsentSince == nil { carPlayAbsentSince = now() }
  }

  func endDrive() async {
    // Only an active scene must be left before the next explicit reopen.
    suppressed = active
    await stopDrive()?.value
  }

  /// Ends the drive, and any Live Activity left from an earlier launch, from the app or Shortcuts.
  func endLiveActivity() async {
    await prepare()
    await endDrive()
  }

  func tick() {
    guard isDriving, let startedAt else { return }
    refreshSetupStatus()
    let elapsed = now().timeIntervalSince(startedAt)
    guard setupStatus == .ready, elapsed.isFinite, elapsed >= 0, elapsed < 8 * 60 * 60 else {
      _ = stopDrive()
      return
    }
    if let carPlayAbsentSince,
      !(0...Self.carPlayAbsenceLimit).contains(now().timeIntervalSince(carPlayAbsentSince))
    {
      _ = stopDrive()
      return
    }
    try? CompassDiagnostics.shared?.observe(.activity, active: compactStatus == .active)
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
    if !sensor.servicesEnabled {
      setupStatus = .servicesDisabled
    } else if !sensor.available {
      setupStatus = .unavailable
    } else if sensor.authorization == .notDetermined {
      setupStatus = .permissionRequired
    } else if sensor.authorization == .denied {
      setupStatus = .denied
    } else if sensor.authorization == .restricted {
      setupStatus = .restricted
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
      setupStatus = .denied
      _ = stopDrive()
    case .interrupted:
      pendingActivityInvalidation = true
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
        if self.pendingActivityInvalidation {
          self.pendingActivityInvalidation = false
          await activity.invalidateReading()
        }
        guard self.isDriving, self.generation == token else { break }
        // A newer interruption invalidates the captured recovery sample as well.
        if self.pendingActivityInvalidation { continue }
        await activity.update(latest)
      }
      if self.drainGeneration == token {
        self.pendingPresentation = nil
        self.drainGeneration = nil
      }
    }
  }

  @discardableResult
  private func stopDrive() -> Task<
    Void, Never
  >? {
    guard isDriving else { return nil }
    generation = UUID()
    pendingActivityInvalidation = false
    pendingPresentation = nil
    drainGeneration = nil
    isDriving = false
    carPlayAbsentSince = nil
    try? CompassDiagnostics.shared?.observe(.activity, active: false)
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
