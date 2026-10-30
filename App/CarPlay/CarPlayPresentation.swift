import CompassCore
import Foundation

struct CarPlayPresentation: Equatable {
  let bearing: String
  private(set) var courseDegrees: Double?
  private(set) var sampleTimestamp: Date?
  let status: String
  let compact: String
  let reference = "Travel · True north"

  init(
    presentation: TravelPresentation, setup: DriveSessionController.SetupStatus,
    driving: Bool, compact: DriveSessionController.CompactStatus, now: Date
  ) {
    self.compact =
      switch compact {
      case .active: "Compact display requested"
      case .starting: "Starting compact display"
      case .unavailable: "Compact display unavailable"
      case .dismissed: "Compact display dismissed"
      case .inactive: "Compact display inactive"
      }
    var bearing = "—"
    if setup != .ready {
      status =
        switch setup {
        case .permissionRequired, .denied: "Enable location on iPhone while parked."
        case .restricted: "Location access is restricted on iPhone."
        case .servicesDisabled: "Turn on Location Services on iPhone while parked."
        case .preciseLocationRequired: "Enable Precise Location on iPhone while parked."
        case .unavailable: "Travel direction unavailable on this device."
        case .ready: "Waiting for travel direction"
        }
    } else if !driving {
      status = "Drive ended. Reopen Compasslet on CarPlay to start."
    } else {
      switch presentation.status {
      case .waiting: status = "Waiting for travel direction"
      case .slow: status = "Stopped or moving too slowly"
      case .unreliable: status = "Direction unreliable"
      case .unavailable: status = "Direction unavailable"
      case .usable:
        if let sample = presentation.sample,
          sample.source == .vehicleCourse, sample.reference == .trueNorth,
          sample.angle.degrees.isFinite,
          now.timeIntervalSince1970.isFinite,
          (0...5).contains(now.timeIntervalSince(sample.timestamp))
        {
          courseDegrees = sample.angle.degrees
          sampleTimestamp = sample.timestamp
          let degrees = Int(sample.angle.degrees.rounded()) % 360
          let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
          bearing = "\(degrees)° \(names[Int((sample.angle.degrees + 22.5) / 45) % 8])"
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
  private var latest: CarPlayPresentation?
  private var lastBearingUpdate: Date?

  mutating func update(_ value: CarPlayPresentation, now: Date) -> CarPlayPresentation? {
    // A fresh input sample is required even while retaining the previous snapshot.
    // Its original timestamp stays visible. Ten-second slots plus the five-second
    // input freshness limit bound snapshot age to fifteen seconds while rendering.
    if value.courseDegrees != nil, let lastBearingUpdate,
      now.timeIntervalSince(lastBearingUpdate) < 10
    {
      return nil
    }
    guard value != latest else { return nil }
    latest = value
    if value.courseDegrees != nil { lastBearingUpdate = now }
    return value
  }
}

/// Lifecycle events never wait behind ActivityKit startup.
@MainActor
final class CarPlayLifecycleBridge {
  private let onActivate: () async -> Void
  private let onResign: () -> Void
  private let onDisconnect: () async -> Void
  private var generation = UUID()

  init(
    activate: @escaping () async -> Void, resign: @escaping () -> Void,
    disconnect: @escaping () async -> Void
  ) {
    onActivate = activate
    onResign = resign
    onDisconnect = disconnect
  }

  convenience init(drive: DriveSessionController) {
    self.init(
      activate: { await drive.carPlayActivated() },
      resign: { drive.carPlayResignedActive() },
      disconnect: { await drive.carPlayDisconnected() })
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
    Task { await onDisconnect() }
  }
}
