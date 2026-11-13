import Testing
@testable import Compass

/// What the sensor reports, and the status it should give.
struct SetupCase: Sendable, CustomTestStringConvertible {
  var services = true
  var available = true
  var authorization = TravelAuthorization.authorized
  var precise = true
  var expected: DriveSessionController.SetupStatus

  var testDescription: String {
    "services \(services), available \(available), \(authorization), precise \(precise)"
  }
}

private let setupCases: [SetupCase] = [
  // Each status with every earlier check passing.
  SetupCase(expected: .ready),
  SetupCase(services: false, expected: .servicesDisabled),
  SetupCase(available: false, expected: .unavailable),
  SetupCase(authorization: .notDetermined, expected: .permissionRequired),
  SetupCase(authorization: .denied, expected: .denied),
  SetupCase(authorization: .restricted, expected: .restricted),
  SetupCase(precise: false, expected: .preciseLocationRequired),
  // An earlier check wins over every later one that also fails.
  SetupCase(
    services: false, available: false, authorization: .denied, precise: false,
    expected: .servicesDisabled),
  SetupCase(
    available: false, authorization: .notDetermined, precise: false, expected: .unavailable),
  SetupCase(authorization: .notDetermined, precise: false, expected: .permissionRequired),
  SetupCase(authorization: .denied, precise: false, expected: .denied),
  SetupCase(authorization: .restricted, precise: false, expected: .restricted),
]

@MainActor
struct SetupStatusTests {
  private func status(
    services: Bool, available: Bool, authorization: TravelAuthorization, precise: Bool
  ) -> DriveSessionController.SetupStatus {
    let sensor = TestTravelSensor(
      authorization: authorization, fullAccuracy: precise, servicesEnabled: services,
      available: available)
    return DriveSessionController.SetupStatus(sensor: sensor)
  }

  @Test(arguments: setupCases)
  func derivesTheFirstFailingCheck(_ setup: SetupCase) {
    let derived = status(
      services: setup.services, available: setup.available, authorization: setup.authorization,
      precise: setup.precise)
    #expect(derived == setup.expected)
  }

  /// Of every combination the sensor can report, only the fully eligible one is ready.
  @Test func onlyAFullyEligibleSensorIsReady() {
    let authorizations: [TravelAuthorization] = [.notDetermined, .authorized, .denied, .restricted]
    var ready = 0
    for services in [true, false] {
      for available in [true, false] {
        for authorization in authorizations {
          for precise in [true, false] {
            let derived = status(
              services: services, available: available, authorization: authorization,
              precise: precise)
            if derived == .ready { ready += 1 }
          }
        }
      }
    }
    #expect(ready == 1)
  }
}
