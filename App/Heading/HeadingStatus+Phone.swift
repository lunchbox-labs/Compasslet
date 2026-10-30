extension HeadingController.Status {
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
