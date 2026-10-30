import CompassCore
import XCTest
#if os(watchOS)
  @testable import CompassWatch
#else
  @testable import Compass
#endif

@MainActor
final class HeadingControllerTests: XCTestCase {
  final class Sensor: HeadingSensor {
    var available = true
    var receive: ((HeadingEvent) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
  }

  func testWaitingLiveStaleAndRecoveryReset() {
    let sensor = Sensor()
    var time = Date(timeIntervalSince1970: 1_000)
    let controller = HeadingController(sensor: sensor, now: { time })
    controller.start()
    XCTAssertEqual(controller.status, .waiting)
    XCTAssertEqual(sensor.starts, 1)
    sensor.receive?(.reading(degrees: 359, accuracy: 3, timestamp: time))
    XCTAssertEqual(controller.status, .live)
    XCTAssertEqual(controller.sample?.source, .deviceHeading)
    XCTAssertEqual(controller.sample?.reference, .magnetic)
    time = time.addingTimeInterval(5)
    controller.tick()
    XCTAssertEqual(controller.status, .live)
    time = time.addingTimeInterval(0.001)
    controller.tick()
    XCTAssertEqual(controller.status, .stale)
    XCTAssertNil(controller.sample)
    sensor.receive?(.reading(degrees: 90, accuracy: 3, timestamp: time))
    XCTAssertEqual(controller.sample?.angle.degrees, 90)
  }

  func testUnavailableDoesNotStartSensor() {
    let sensor = Sensor()
    sensor.available = false
    let controller = HeadingController(sensor: sensor)
    controller.start()
    XCTAssertEqual(controller.status, .unavailable)
    XCTAssertEqual(sensor.starts, 0)
    XCTAssertNil(controller.sample)
  }

  func testInvalidAndDeniedClearReadoutAndRecoveryResetsSmoothing() {
    let sensor = Sensor()
    let time = Date(timeIntervalSince1970: 1_000)
    let controller = HeadingController(sensor: sensor, now: { time })
    controller.start()
    sensor.receive?(.reading(degrees: 180, accuracy: 2, timestamp: time))
    sensor.receive?(.reading(degrees: 0, accuracy: -1, timestamp: time))
    XCTAssertEqual(controller.status, .calibration)
    XCTAssertNil(controller.sample)
    sensor.receive?(.reading(degrees: 0, accuracy: 2, timestamp: time))
    XCTAssertEqual(controller.sample?.angle.degrees, 0)
    sensor.receive?(.denied)
    XCTAssertEqual(controller.status, .denied)
    XCTAssertNil(controller.sample)
    sensor.receive?(.interrupted)
    XCTAssertEqual(controller.status, .interrupted)
  }

  func testStopClearsAndIgnoresLateCallbacks() {
    let sensor = Sensor()
    let time = Date(timeIntervalSince1970: 1_000)
    let controller = HeadingController(sensor: sensor, now: { time })
    controller.start()
    sensor.receive?(.reading(degrees: 90, accuracy: 1, timestamp: time))
    let priorStops = sensor.stops
    controller.stop()
    XCTAssertEqual(sensor.stops, priorStops + 1)
    sensor.receive?(.reading(degrees: 180, accuracy: 1, timestamp: time))
    XCTAssertEqual(controller.status, .inactive)
    XCTAssertNil(controller.sample)
    controller.start()
    sensor.receive?(.reading(degrees: 180, accuracy: 1, timestamp: time))
    XCTAssertEqual(controller.sample?.angle.degrees, 180)
  }

  func testCircularSmoothingAndReducedMotion() {
    let sensor = Sensor()
    let time = Date(timeIntervalSince1970: 1_000)
    let controller = HeadingController(sensor: sensor, now: { time })
    controller.start()
    sensor.receive?(.reading(degrees: 359, accuracy: 1, timestamp: time))
    sensor.receive?(.reading(degrees: 1, accuracy: 1, timestamp: time))
    XCTAssertEqual(controller.sample?.angle.degrees, 359.5)
    controller.setReducedMotion(true)
    sensor.receive?(.reading(degrees: 90, accuracy: 1, timestamp: time))
    XCTAssertEqual(controller.sample?.angle.degrees, 90)
    sensor.receive?(.reading(degrees: 180, accuracy: 1, timestamp: time))
    XCTAssertEqual(controller.sample?.angle.degrees, 180)
    sensor.receive?(.reading(degrees: 180, accuracy: 1, timestamp: time.addingTimeInterval(1)))
    XCTAssertEqual(controller.status, .stale)
    XCTAssertNil(controller.sample)
  }
}
