extension DriveSessionController {
  /// Whether location lets a drive run, and if not, what the user has to change first.
  enum SetupStatus {
    case ready, permissionRequired, denied, restricted, servicesDisabled, preciseLocationRequired,
      unavailable

    /// Reads the sensor, checking in order: Location Services, whether the app can run travel
    /// location at all, the permission, then precise location. The first check that fails names
    /// the status.
    @MainActor
    init(sensor: some TravelLocationSensor) {
      if !sensor.servicesEnabled {
        self = .servicesDisabled
      } else if !sensor.available {
        self = .unavailable
      } else if sensor.authorization == .notDetermined {
        self = .permissionRequired
      } else if sensor.authorization == .denied {
        self = .denied
      } else if sensor.authorization == .restricted {
        self = .restricted
      } else if !sensor.fullAccuracy {
        self = .preciseLocationRequired
      } else {
        self = .ready
      }
    }
  }
}
