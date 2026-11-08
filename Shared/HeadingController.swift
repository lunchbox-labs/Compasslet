import CompassCore
import CoreLocation
import Foundation
import Observation

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
@MainActor @Observable
final class HeadingController {
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

  /// Set through `setStatus(_:)`, only when it changes, so a status that holds across readings
  /// doesn't redraw the views that show it at the heading rate.
  private(set) var status: Status = .inactive
  /// The heading shown, which changes at the heading rate. Only the views that draw it read it;
  /// the rest of the screen reads `hasSample`. Set through `setSample(_:)`.
  private(set) var sample: CompassSample?
  /// Whether there is a heading to show, which changes far less often than `sample`.
  private(set) var hasSample = false
  private let sensor: any HeadingSensor
  private let now: () -> Date
  @ObservationIgnored private var smoother = CompassSmoother(fraction: 0.25)
  @ObservationIgnored private var active = false
  @ObservationIgnored private var reducedMotion = false
  @ObservationIgnored private var session: UUID?
  static let maximumAge: TimeInterval = 5
  /// In stepped mode the shown heading holds until the sensor moves at least this far, so a
  /// rotating dial steps between settled readings instead of drifting with every small sample.
  /// A settled reading can therefore differ from the sensor by up to this many degrees.
  static let reducedMotionStep: Double = 4

  init(sensor: any HeadingSensor, now: @escaping () -> Date = Date.init) {
    self.sensor = sensor
    self.now = now
    sensor.receive = { [weak self] event in self?.receive(event) }
  }

  /// Switches between smoothed headings and stepped headings. Pass true only while a rotating
  /// dial is shown under Reduce Motion; a text reading is more accurate when smoothed.
  func setReducedMotion(_ value: Bool) {
    reducedMotion = value
    smoother?.reset()
  }

  func start() {
    stop()
    active = true
    guard sensor.available else {
      setStatus(.unavailable)
      return
    }
    setStatus(.waiting)
    sensor.start()
  }

  func stop(preservingLastReading: Bool = false) {
    if preservingLastReading { tick() }
    active = false
    sensor.stop()
    if preservingLastReading {
      smoother?.reset()
      if sample != nil || status == .waiting { setStatus(.inactive) }
    } else {
      clear(.inactive)
    }
  }

  /// Cancellation stops sensing; the phone may retain a last reading for its inactive preview.
  func run(preservingLastReadingOnStop: Bool = false) async {
    guard !Task.isCancelled else { return }
    let token = UUID()
    session = token
    start()
    defer {
      if session == token {
        stop(preservingLastReading: preservingLastReadingOnStop)
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
    guard active else {
      if case .denied = event { clear(.denied) }
      return
    }
    switch event {
    case .denied: clear(.denied)
    case .interrupted: clear(.interrupted)
    case .reading(let degrees, let accuracy, let timestamp):
      guard
        let reading = CompassSample(
          degrees: degrees, source: .deviceHeading, reference: .magnetic,
          accuracyDegrees: accuracy, timestamp: timestamp)
      else {
        clear(.calibration)
        return
      }
      guard reading.isFresh(now: now(), maximumAge: Self.maximumAge) else {
        clear(.stale)
        return
      }
      if reducedMotion {
        smoother?.reset()
        if let held = heldReading(for: reading) {
          setSample(held)
          setStatus(.live)
          return
        }
      }
      setSample(smoother?.update(reading, now: now(), maximumAge: Self.maximumAge))
      setStatus(sample == nil ? .interrupted : .live)
    }
  }

  /// Keeps the displayed angle for a small change while adopting the new sample's metadata, so
  /// freshness and accuracy stay current. Larger changes are shown directly without smoothing.
  private func heldReading(for reading: CompassSample) -> CompassSample? {
    guard let current = sample, reading.timestamp >= current.timestamp,
      abs(current.angle.shortestDelta(to: reading.angle)) < Self.reducedMotionStep
    else { return nil }
    return CompassSample(
      degrees: current.angle.degrees, source: reading.source, reference: reading.reference,
      accuracyDegrees: reading.accuracyDegrees, timestamp: reading.timestamp)
  }

  private func setStatus(_ next: Status) {
    if status != next { status = next }
  }

  private func setSample(_ next: CompassSample?) {
    sample = next
    if hasSample != (next != nil) { hasSample = next != nil }
  }

  private func clear(_ next: Status) {
    setSample(nil)
    smoother?.reset()
    setStatus(next)
  }
}
