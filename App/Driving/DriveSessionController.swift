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

  private let sensor: any TravelLocationSensor
  private let activity: any CompassActivityPresenting
  private let now: () -> Date
  private let automaticTick: Bool
  private let reloadWidget: @MainActor (String) -> Void
  private let diagnose:
    @MainActor (CompassDiagnostics.WidgetKind, CompassDiagnostics.WidgetOutcome) -> Void
  private let writeWidget: @MainActor (LatestCourseSnapshot) -> Void
  private var widgetValue = LatestCourseSnapshot.unavailable(at: .distantPast)
  private var lastWidgetReload: Date?
  private var pendingWidgetReload = false
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
    now: @escaping () -> Date = Date.init, automaticTick: Bool = true,
    reloadWidget: @escaping @MainActor (String) -> Void = { _ in },
    writeWidget: @escaping @MainActor (LatestCourseSnapshot) -> Void = { _ in },
    diagnose:
      @escaping @MainActor (CompassDiagnostics.WidgetKind, CompassDiagnostics.WidgetOutcome) -> Void =
      {
        try? CompassDiagnostics.shared?.recordWidget($0, outcome: $1)
      }
  ) {
    self.sensor = sensor
    self.activity = activity
    self.now = now
    self.automaticTick = automaticTick
    self.reloadWidget = reloadWidget
    self.writeWidget = writeWidget
    self.diagnose = diagnose
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
  func phoneBecameActive() async {
    await prepare()
    guard !Task.isCancelled else { return }
    refreshSetupStatus()
    if setupStatus != .ready { _ = stopDrive(reason: setupStopReason) }
    requestPhoneAuthorization(isForeground: true)
  }

  func requestPhoneAuthorization(isForeground: Bool) {
    guard isForeground, !requestedPermission, setupStatus == .permissionRequired,
      sensor.authorization == .notDetermined
    else { return }
    requestedPermission = true
    sensor.requestAuthorization()
    refreshSetupStatus()
  }

  func carPlayActivated() async {
    active = true
    await prepare()
    refreshSetupStatus()
    guard active, !suppressed, !isDriving else { return }
    guard setupStatus == .ready else {
      diagnose(.acquisitionStopped, setupStopReason)
      return
    }
    let token = UUID()
    generation = token
    sensor.receive = { [weak self] event in self?.receive(event, generation: token) }
    do { try sensor.start() } catch {
      sensor.stop()
      sensor.receive = nil
      setupStatus = .unavailable
      diagnose(.acquisitionStopped, .startFailed)
      return
    }
    isDriving = true
    diagnose(.acquisitionStarted, .success)
    try? CompassDiagnostics.shared?.observe(.widget, active: true)
    startedAt = now()
    lastWidgetReload = nil
    pendingWidgetReload = false
    filter.reset()
    lastReading = nil
    presentation = TravelPresentation(sample: nil, status: .waiting)
    widgetValue = Self.widgetSnapshot(presentation, now: now())
    writeWidget(widgetValue)
    reloadWidget("session started")
    compactStatus = .starting
    startTicker()
    let operation = enqueue { [weak self, activity] in
      guard let self, self.isDriving, self.generation == token else { return }
      activity.onDismiss = { [weak self] in
        guard let self, self.isDriving, self.generation == token else { return }
        // The drive belongs to the CarPlay scene. ActivityKit ends activities on its own, so
        // losing the compact card only ends its updates for the rest of this drive.
        self.compactStatus = .dismissed
      }
      do {
        try await activity.start()
        guard self.isDriving, self.generation == token, self.compactStatus == .starting else {
          return
        }
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
    await stopDrive(reason: .disconnected)?.value
  }

  func endDrive() async {
    // Only an active scene must be left before the next explicit reopen.
    suppressed = active
    await stopDrive()?.value
  }

  func tick() {
    guard isDriving, let startedAt else { return }
    refreshSetupStatus()
    let elapsed = now().timeIntervalSince(startedAt)
    guard setupStatus == .ready, elapsed.isFinite, elapsed >= 0, elapsed < 8 * 60 * 60 else {
      _ = stopDrive(reason: setupStatus == .ready ? .timeout : setupStopReason)
      return
    }
    try? CompassDiagnostics.shared?.observe(.widget, active: true)
    try? CompassDiagnostics.shared?.observe(.activity, active: compactStatus == .active)
    if let lastReading,
      !(0...5).contains(now().timeIntervalSince(lastReading.timestamp))
    {
      publish(filter.update(nil, now: now()), preserveWidgetHistory: true)
      self.lastReading = nil
    }
    flushWidgetReload()
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
    guard setupStatus == .ready else { _ = stopDrive(reason: setupStopReason); return }
    switch event {
    case .authorizationChanged: break
    case .authorizationLost:
      setupStatus = .denied
      _ = stopDrive(reason: .permission)
    case .interrupted:
      lastReading = nil
      publish(filter.update(nil, now: now()))
    case .reading(let reading):
      lastReading = reading
      publish(filter.update(reading, now: now()))
    }
  }

  private func publish(_ value: TravelPresentation, preserveWidgetHistory: Bool = false) {
    let invalidation = value.status != .usable && value.status != presentation.status
    presentation = value
    let hadWidgetBearing = widgetValue.bearing != nil
    widgetValue =
      preserveWidgetHistory
      ? widgetValue.validated(at: now())
      : Self.widgetSnapshot(value, now: now(), observedAt: lastReading?.timestamp)
    if invalidation || (hadWidgetBearing && widgetValue.bearing == nil) { writeWidget(widgetValue) }
    pendingWidgetReload = true
    flushWidgetReload()
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

  private func flushWidgetReload() {
    let date = now()
    guard pendingWidgetReload,
      lastWidgetReload.map({ date.timeIntervalSince($0) >= 1 }) ?? true
    else { return }
    pendingWidgetReload = false
    lastWidgetReload = date
    writeWidget(widgetValue.validated(at: date))
    reloadWidget("latest presentation")
  }

  static func widgetSnapshot(
    _ value: TravelPresentation, now: Date, observedAt: Date? = nil
  ) -> LatestCourseSnapshot {
    let status: LatestCourseSnapshot.Status
    switch value.status {
    case .waiting: status = .waiting
    case .usable: status = .usable
    case .slow: status = .slow
    case .unreliable: status = .unreliable
    case .unavailable: status = .unavailable
    }
    guard status == .usable else {
      return LatestCourseSnapshot(bearing: nil, status: status, sampleTime: observedAt ?? now)
        .validated(at: now)
    }
    guard let sample = value.sample, sample.source == .vehicleCourse,
      sample.reference == .trueNorth, sample.isFresh(now: now, maximumAge: 5)
    else { return .unavailable(at: now) }
    return LatestCourseSnapshot(
      bearing: sample.angle.degrees, status: .usable, sampleTime: sample.timestamp
    ).validated(at: now)
  }

  private var setupStopReason: CompassDiagnostics.WidgetOutcome {
    switch setupStatus {
    case .denied, .restricted, .permissionRequired, .preciseLocationRequired: .permission
    default: .servicesUnavailable
    }
  }

  @discardableResult
  private func stopDrive(reason: CompassDiagnostics.WidgetOutcome = .explicitStop) -> Task<
    Void, Never
  >? {
    guard isDriving else { return nil }
    generation = UUID()
    pendingPresentation = nil
    drainGeneration = nil
    isDriving = false
    diagnose(.acquisitionStopped, reason)
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
    lastWidgetReload = nil
    pendingWidgetReload = false
    widgetValue = .unavailable(at: now())
    writeWidget(widgetValue)
    reloadWidget("session ended")
    try? CompassDiagnostics.shared?.observe(.widget, active: false)
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
