/// The phone's copy for each heading status.
extension HeadingController.Status {
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

  /// The title in the compact layout, shortened where the full title runs long.
  var compactTitle: String {
    switch self {
    case .stale: "Heading stale"
    case .calibration: "Calibrate compass"
    case .unavailable: "Compass unavailable"
    case .denied: "Heading access denied"
    case .inactive, .waiting, .live, .interrupted: title
    }
  }

  var detail: String {
    switch self {
    case .inactive: "Return to the app to resume."
    case .waiting: "Hold your phone flat with its top pointing ahead."
    case .live: "The top of your phone points in this direction."
    case .stale, .interrupted: "Move your phone gently. Reopen the app if readings do not resume."
    case .calibration:
      "Move away from magnets and metal. Follow any system calibration instructions."
    case .unavailable: "This device has no available compass. Simulator cannot provide heading."
    case .denied: "Check Location Services restrictions and this app’s access in Settings."
    }
  }
}
