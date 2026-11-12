/// The phone's copy for each location setup status. CarPlay and Shortcuts word their own.
extension DriveSessionController.SetupStatus {
  /// The compass screen's location notice, or nil when location needs nothing.
  var notice: String? {
    switch self {
    case .ready: nil
    case .permissionRequired: "Enable Location"
    case .denied: "Location access denied"
    case .restricted: "Location access is restricted"
    case .servicesDisabled: "Location Services is off"
    case .preciseLocationRequired: "Approximate location · Enable Precise Location"
    case .unavailable: "CarPlay travel direction unavailable"
    }
  }

  /// The notice in the compact layout, which shows it only when `notice` isn't nil.
  var compactNotice: String {
    switch self {
    case .ready: "Location Enabled"
    case .permissionRequired: "Enable Location"
    case .denied: "Location denied"
    case .restricted: "Location restricted"
    case .servicesDisabled: "Location Services off"
    case .preciseLocationRequired: "Approximate location"
    case .unavailable: "CarPlay unavailable"
    }
  }

  /// The value beside "Location Enabled" in Settings.
  var locationEnabledValue: String {
    switch self {
    case .ready, .preciseLocationRequired: "Yes"
    case .permissionRequired, .denied, .restricted, .servicesDisabled, .unavailable: "No"
    }
  }

  /// What Settings says about location.
  var settingsDetail: String {
    switch self {
    case .ready:
      "Precise location is enabled for phone coordinates, elevation, and CarPlay travel direction."
    case .permissionRequired: "Location permission has not been granted yet."
    case .denied:
      "Allow location while using the app for phone location details and CarPlay travel direction."
    case .restricted: "Location access is restricted by this device’s settings or management."
    case .servicesDisabled:
      "Location Services is off. Turn it on in iPhone Settings under Privacy & Security."
    case .preciseLocationRequired:
      "Location is allowed, but CarPlay travel direction needs Precise Location."
    case .unavailable: "Travel direction is unavailable on this device."
    }
  }

  /// Whether iPhone Settings can change this status, so Settings offers to open it.
  var canOpenSettings: Bool {
    switch self {
    case .denied, .servicesDisabled, .preciseLocationRequired: true
    case .ready, .permissionRequired, .restricted, .unavailable: false
    }
  }
}
