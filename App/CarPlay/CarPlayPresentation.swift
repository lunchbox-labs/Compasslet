import CompassCore
import Foundation
import Observation

struct CarPlayPresentation: Equatable {
  let bearing: String
  private(set) var courseDegrees: Double?
  private(set) var sampleTimestamp: Date?
  let status: String

  init(
    presentation: TravelPresentation, setup: DriveSessionController.SetupStatus,
    driving: Bool, now: Date
  ) {
    var bearing = "—"
    if setup != .ready {
      status =
        switch setup {
        case .permissionRequired, .denied: "Enable location on iPhone while parked."
        case .restricted: "Location access is restricted on iPhone."
        case .servicesDisabled: "Turn on Location Services on iPhone while parked."
        case .preciseLocationRequired: "Enable Precise Location on iPhone while parked."
        case .unavailable: "Travel direction unavailable on this device."
        case .ready: "Start moving"
        }
    } else if !driving {
      status = "Drive ended. Reopen Compasslet on CarPlay to start."
    } else {
      switch presentation.status {
      case .waiting: status = "Start moving"
      case .slow: status = "Stopped or moving too slowly"
      case .unreliable: status = "Direction unreliable"
      case .unavailable: status = "Direction unavailable"
      case .usable:
        if let sample = presentation.sample, sample.isCurrent(at: now) {
          courseDegrees = sample.angle.degrees
          sampleTimestamp = sample.timestamp
          let degrees = sample.angle.roundedDegrees
          bearing = "\(degrees)° \(CompassPoint(angle: sample.angle).abbreviation)"
          status = "Updates limited to once every 10 seconds"
        } else {
          status = "Direction unavailable"
        }
      }
    }
    self.bearing = bearing
  }

}

/// Publishes explicitly sampled course while checking current input on every render.
struct CarPlayUpdateGate {
  /// How long a shown bearing stays before another bearing may replace it.
  static let slot: TimeInterval = 10
  private var latest: CarPlayPresentation?
  private var lastBearingUpdate: Date?
  /// When the slot that held back the last value passed in ends, or nil when that value was
  /// shown or already showing. A held value shows only when it is passed in again from then.
  private(set) var heldUntil: Date?

  mutating func update(_ value: CarPlayPresentation, now: Date) -> CarPlayPresentation? {
    heldUntil = nil
    guard value != latest else { return nil }
    // A fresh input sample is required even while retaining the previous snapshot.
    // Its original timestamp stays visible. Ten-second slots plus the five-second
    // input freshness limit bound snapshot age to fifteen seconds while rendering. A clock set
    // back before the last bearing ends its slot, rather than adding that time to the wait.
    if value.courseDegrees != nil, let lastBearingUpdate, now >= lastBearingUpdate {
      // The same date is compared and reported, so a pass at `heldUntil` is never held again.
      let slotEnd = lastBearingUpdate.addingTimeInterval(Self.slot)
      if now < slotEnd {
        heldUntil = slotEnd
        return nil
      }
    }
    latest = value
    if value.courseDegrees != nil { lastBearingUpdate = now }
    return value
  }
}

/// Passes the drive to the CarPlay template through the update gate: once at the start, again
/// whenever a value the template reads from the drive changes or Debug Mode is switched, and once
/// more when a slot that held a bearing back ends, so that bearing still shows when nothing else
/// changes.
@MainActor
final class CarPlayTemplateUpdates {
  private let drive: DriveSessionController
  private let diagnostics: CompassDiagnostics?
  private let clock: any DriveClock
  private let pass: @MainActor (CarPlayPresentation?) -> Void
  private var gate = CarPlayUpdateGate()
  private var observing: Task<Void, Never>?
  /// The one timer for the end of the slot holding a bearing back, and when it fires.
  private var slotEnd: (date: Date, timer: DriveTimer)?

  /// `pass` runs on every pass, with the value to show or nil when the template keeps its own.
  /// A pass when Debug Mode is switched lets the owner start or stop observing diagnostics.
  init(
    drive: DriveSessionController, diagnostics: CompassDiagnostics? = CompassDiagnostics.shared,
    clock: any DriveClock = SystemDriveClock(),
    pass: @escaping @MainActor (CarPlayPresentation?) -> Void
  ) {
    self.drive = drive
    self.diagnostics = diagnostics
    self.clock = clock
    self.pass = pass
  }

  isolated deinit { stop() }

  /// Follows the drive until `stop`. The sequence's first value makes a pass once the task starts,
  /// after any pass the caller made itself, and each later change makes another.
  func start() {
    guard observing == nil else { return }
    let drive = drive
    let diagnostics = diagnostics
    let changes = Observations { @MainActor in
      // Reading everything `update` reads from the drive ends each wait at the next change.
      _ = (drive.presentation, drive.setupStatus, drive.isDriving, diagnostics?.isEnabled)
    }
    observing = Task { [weak self] in
      for await _ in changes {
        guard let self, !Task.isCancelled else { return }
        self.update()
      }
    }
  }

  /// Passes the drive as it is now through the gate, keeping one timer for the end of the slot
  /// while the gate holds a bearing back.
  func update() {
    let now = clock.now
    let value = CarPlayPresentation(
      presentation: drive.presentation, setup: drive.setupStatus, driving: drive.isDriving,
      now: now)
    let next = gate.update(value, now: now)
    armSlotEnd()
    pass(next)
  }

  /// Stops following the drive and drops a pending slot end, as when CarPlay disconnects.
  func stop() {
    observing?.cancel()
    observing = nil
    cancelSlotEnd()
  }

  private func armSlotEnd() {
    guard let date = gate.heldUntil else {
      cancelSlotEnd()
      return
    }
    // Changes within the slot hold their value until the same time, so the timer stays.
    guard slotEnd?.date != date else { return }
    cancelSlotEnd()
    let timer = clock.timer(at: date) { [weak self] in
      guard let self else { return }
      self.slotEnd = nil
      self.update()
    }
    slotEnd = (date, timer)
  }

  private func cancelSlotEnd() {
    slotEnd?.timer.cancel()
    slotEnd = nil
  }
}

/// Checks the car's light or dark style and display scale while the CarPlay scene is active,
/// once `interval` has passed with no other check. CarPlay tells a non-navigation app of no
/// change to them, and passes come only with drive changes, so without this an idle scene would
/// keep the dial's old style. Each pass checks too, so while passes keep coming this never fires.
@MainActor
final class CarPlayStyleCheck {
  /// How long the active scene goes without a check before it checks.
  static let interval: TimeInterval = 1
  private enum State {
    case inactive
    case active(nextCheck: DriveTimer)
  }
  private let clock: any DriveClock
  private let checkStyle: @MainActor () -> Void
  private var state = State.inactive

  /// `check` compares the car's traits with the ones the dial was drawn for, and redraws only
  /// when they differ.
  init(clock: any DriveClock = SystemDriveClock(), check: @escaping @MainActor () -> Void) {
    self.clock = clock
    checkStyle = check
  }

  isolated deinit { resign() }

  /// Checks now, then again whenever the scene goes `interval` without a check, until `resign`.
  func activate() {
    resign()
    state = .active(nextCheck: scheduleCheck())
    checkStyle()
  }

  /// Checks now. While the scene is active, the next check waits a full `interval` from now.
  func check() {
    if case .active(let nextCheck) = state {
      nextCheck.cancel()
      state = .active(nextCheck: scheduleCheck())
    }
    checkStyle()
  }

  /// Stops checking on its own, as when the scene resigns active or disconnects.
  func resign() {
    if case .active(let nextCheck) = state { nextCheck.cancel() }
    state = .inactive
  }

  private func scheduleCheck() -> DriveTimer {
    clock.timer(at: clock.now.addingTimeInterval(Self.interval)) { [weak self] in
      self?.check()
    }
  }
}

/// Lifecycle events never wait behind ActivityKit startup.
@MainActor
final class CarPlayLifecycleBridge {
  private let onActivate: () async -> Void
  private let onResign: () -> Void
  private let onDisconnect: () -> Void
  private var generation = UUID()

  init(
    activate: @escaping () async -> Void, resign: @escaping () -> Void,
    disconnect: @escaping () -> Void
  ) {
    onActivate = activate
    onResign = resign
    onDisconnect = disconnect
  }

  convenience init(drive: DriveSessionController) {
    self.init(
      activate: { await drive.carPlayActivated() },
      resign: { drive.carPlayResignedActive() },
      disconnect: { drive.carPlayDisconnected() })
  }

  func activate() {
    let token = UUID()
    generation = token
    Task { @MainActor in
      guard generation == token else { return }
      await onActivate()
    }
  }

  func resign() {
    generation = UUID()
    onResign()
  }

  func disconnect() {
    resign()
    onDisconnect()
  }
}
