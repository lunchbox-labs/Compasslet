import Combine
import CompassCore
import CoreLocation
import Foundation

/// Events contain magnetic device heading only; travel course never enters this pipeline.
enum HeadingEvent {
  case reading(degrees: Double, accuracy: Double, timestamp: Date)
  case denied
  case interrupted
}

@MainActor
protocol HeadingSensor: AnyObject {
  var available: Bool { get }
  var receive: ((HeadingEvent) -> Void)? { get set }
  func start()
  func stop()
}

// The manager is created and used on the main actor/main runloop, where it delivers
// delegate callbacks. The legacy delegate protocol does not express that isolation.
@MainActor
final class DeviceHeadingSensor: NSObject, HeadingSensor, @preconcurrency CLLocationManagerDelegate
{
  private let manager = CLLocationManager()
  var receive: ((HeadingEvent) -> Void)?
  var available: Bool { CLLocationManager.headingAvailable() }

  override init() {
    super.init()
    manager.delegate = self
    manager.headingFilter = 1
  }

  func start() { manager.startUpdatingHeading() }
  func stop() { manager.stopUpdatingHeading() }

  func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    receive?(
      .reading(
        degrees: newHeading.magneticHeading, accuracy: newHeading.headingAccuracy,
        timestamp: newHeading.timestamp))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    let code = (error as? CLError)?.code
    receive?(code == .denied ? .denied : .interrupted)
  }

  #if os(iOS)
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
      true
    }
  #endif
}

/// All visible readouts are removed on invalid, stale, or interrupted input.
@MainActor
final class HeadingController: ObservableObject {
  enum Status: Equatable {
    case inactive, waiting, live, stale, calibration, unavailable, denied, interrupted

    var title: String {
      switch self {
      case .inactive: "Compass paused"
      case .waiting: "Finding north…"
      case .live: "Magnetic north"
      case .stale: "Waiting for a fresh heading"
      case .calibration: "Compass needs calibration"
      case .unavailable: "Heading sensor unavailable"
      case .denied: "Heading access unavailable"
      case .interrupted: "Heading interrupted"
      }
    }

  }

  @Published private(set) var status: Status = .inactive
  @Published private(set) var sample: CompassSample?
  private let sensor: any HeadingSensor
  private let now: () -> Date
  private var smoother = CompassSmoother(fraction: 0.25)
  private var active = false
  private var reducedMotion = false
  private var session: UUID?
  static let maximumAge: TimeInterval = 5

  init(sensor: any HeadingSensor, now: @escaping () -> Date = Date.init) {
    self.sensor = sensor
    self.now = now
    sensor.receive = { [weak self] event in self?.receive(event) }
  }

  func setReducedMotion(_ value: Bool) {
    reducedMotion = value
    smoother?.reset()
  }

  func start() {
    stop()
    active = true
    guard sensor.available else {
      status = .unavailable
      return
    }
    status = .waiting
    sensor.start()
  }

  func stop() {
    active = false
    sensor.stop()
    clear(.inactive)
  }

  /// Owned by the view task; cancellation stops the sensor and removes its readout.
  func run() async {
    let token = UUID()
    session = token
    start()
    defer {
      if session == token {
        stop()
        session = nil
      }
    }
    while !Task.isCancelled {
      do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
      guard session == token else { break }
      tick()
    }
  }

  func tick() {
    guard active, let sample else { return }
    if !sample.isFresh(now: now(), maximumAge: Self.maximumAge) { clear(.stale) }
  }

  private func receive(_ event: HeadingEvent) {
    guard active else { return }
    switch event {
    case .denied: clear(.denied)
    case .interrupted: clear(.interrupted)
    case .reading(let degrees, let accuracy, let timestamp):
      guard
        let reading = CompassSample(
          degrees: degrees, source: .deviceHeading, reference: .magnetic,
          accuracy: accuracy, timestamp: timestamp)
      else {
        clear(.calibration)
        return
      }
      guard reading.isFresh(now: now(), maximumAge: Self.maximumAge) else {
        clear(.stale)
        return
      }
      if reducedMotion { smoother?.reset() }
      sample = smoother?.update(reading, now: now(), maximumAge: Self.maximumAge)
      status = sample == nil ? .interrupted : .live
    }
  }

  private func clear(_ next: Status) {
    sample = nil
    smoother?.reset()
    status = next
  }
}
