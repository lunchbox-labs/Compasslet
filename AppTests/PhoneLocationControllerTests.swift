import CoreLocation
import XCTest
@testable import Compass

@MainActor
final class PhoneLocationControllerTests: XCTestCase {
  private final class Sensor: PhoneLocationSensor {
    var authorized = true
    var precise = true
    var servicesEnabled = true
    var receive: ((PhoneLocationEvent) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
  }

  private final class CityLookup: PhoneCityLookup {
    var completions: [@MainActor (String?) -> Void] = []
    var cancellations = 0
    func lookup(_ location: CLLocation, completion: @escaping @MainActor (String?) -> Void) {
      completions.append(completion)
    }
    func cancel() { cancellations += 1 }
  }

  func testCityRequestsAreThrottledAndFailuresKeepCoordinates() {
    let sensor = Sensor()
    let lookup = CityLookup()
    var now = time
    let controller = PhoneLocationController(sensor: sensor, cityLookup: lookup, now: { now })
    controller.start()
    sensor.receive?(.location(fix(at: now)))
    XCTAssertEqual(lookup.completions.count, 1)
    sensor.receive?(.location(fix(at: now)))
    XCTAssertEqual(lookup.completions.count, 1)
    lookup.completions[0](nil)
    XCTAssertNotNil(controller.location)
    XCTAssertEqual(controller.elevation, -20)
    now += 59
    sensor.receive?(.location(fix(at: now)))
    XCTAssertEqual(lookup.completions.count, 1)
    now += 1
    sensor.receive?(.location(fix(at: now)))
    XCTAssertEqual(lookup.completions.count, 2)
    lookup.completions[1]("Sample City")
    now += 60
    sensor.receive?(.location(fix(at: now)))
    XCTAssertEqual(lookup.completions.count, 2)
    XCTAssertEqual(controller.city, "Sample City")
  }

  func testMovementAndStopDiscardLateCityResults() {
    let sensor = Sensor()
    let lookup = CityLookup()
    var now = time
    let controller = PhoneLocationController(sensor: sensor, cityLookup: lookup, now: { now })
    controller.start()
    sensor.receive?(.location(fix(at: now)))
    now += 61
    let distant = CLLocation(
      coordinate: .init(latitude: 13, longitude: -78), altitude: 1,
      horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now)
    sensor.receive?(.location(distant))
    XCTAssertEqual(lookup.completions.count, 2)
    lookup.completions[0]("Old City")
    XCTAssertNil(controller.city)
    lookup.completions[1]("Current City")
    XCTAssertEqual(controller.city, "Current City")
    controller.stop()
    lookup.completions[1]("Late City")
    XCTAssertNil(controller.city)
    XCTAssertNil(controller.location)
    controller.start()
    sensor.receive?(.location(distant))
    XCTAssertEqual(lookup.completions.count, 2)
  }

  private let time = Date(timeIntervalSince1970: 1_000)
  private func fix(at date: Date, verticalAccuracy: Double = 5) -> CLLocation {
    CLLocation(
      coordinate: .init(latitude: 12, longitude: -78), altitude: -20,
      horizontalAccuracy: 5, verticalAccuracy: verticalAccuracy, timestamp: date)
  }

  func testForegroundAuthorizationControlsAcquisitionAndClearsOnRevocation() {
    let sensor = Sensor()
    sensor.authorized = false
    let controller = PhoneLocationController(
      sensor: sensor, cityLookup: CityLookup(), now: { self.time })
    controller.start()
    XCTAssertEqual(sensor.starts, 0)
    sensor.authorized = true
    sensor.receive?(.authorizationChanged)
    XCTAssertEqual(sensor.starts, 1)
    sensor.receive?(.location(fix(at: time)))
    XCTAssertNotNil(controller.location)
    sensor.authorized = false
    sensor.receive?(.authorizationChanged)
    XCTAssertNil(controller.location)
    XCTAssertEqual(sensor.stops, 1)
  }

  func testStopRejectsLateCallbacksAndNextStartRequiresFreshFix() {
    let sensor = Sensor()
    let controller = PhoneLocationController(
      sensor: sensor, cityLookup: CityLookup(), now: { self.time })
    controller.start()
    sensor.receive?(.location(fix(at: time)))
    controller.stop()
    sensor.receive?(.location(fix(at: time)))
    XCTAssertNil(controller.location)
    controller.start()
    XCTAssertNil(controller.location)
    XCTAssertEqual(sensor.starts, 2)
  }

  func testFutureAndExpiredFixesNeverRemainVisible() {
    let sensor = Sensor()
    var now = time
    let controller = PhoneLocationController(sensor: sensor, cityLookup: CityLookup(), now: { now })
    controller.start()
    sensor.receive?(.location(fix(at: time + 1)))
    XCTAssertNil(controller.location)
    sensor.receive?(.location(fix(at: time)))
    XCTAssertNotNil(controller.location)
    now += 31
    controller.tick()
    XCTAssertNil(controller.location)
    sensor.receive?(.location(fix(at: time)))
    XCTAssertNil(controller.location)
  }

  func testPoorAltitudeDoesNotHideValidCoordinatesOrInventZeroElevation() {
    let sensor = Sensor()
    let controller = PhoneLocationController(
      sensor: sensor, cityLookup: CityLookup(), now: { self.time })
    controller.start()
    for accuracy in [-1.0, 0, 100, .nan] {
      sensor.receive?(.location(fix(at: time, verticalAccuracy: accuracy)))
      XCTAssertNotNil(controller.location)
      XCTAssertNil(controller.elevation)
    }
    sensor.receive?(.location(fix(at: time)))
    XCTAssertEqual(controller.elevation, -20)
  }

  func testReducedAccuracyAndServiceFailureRemovePreciseValues() {
    let sensor = Sensor()
    let controller = PhoneLocationController(
      sensor: sensor, cityLookup: CityLookup(), now: { self.time })
    controller.start()
    sensor.receive?(.location(fix(at: time)))
    sensor.precise = false
    sensor.receive?(.authorizationChanged)
    XCTAssertNil(controller.location)
    XCTAssertTrue(controller.approximate)
    sensor.receive?(.location(fix(at: time)))
    XCTAssertNil(controller.location)
    sensor.servicesEnabled = false
    sensor.receive?(.authorizationChanged)
    XCTAssertNil(controller.location)
    XCTAssertEqual(sensor.stops, 1)
  }
}
