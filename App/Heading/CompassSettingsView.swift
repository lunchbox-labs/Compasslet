import SwiftUI
import UIKit

struct CompassSettingsView: View {
  @ObservedObject var drive: DriveSessionController
  let close: () -> Void
  @AccessibilityFocusState private var closeFocused: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section("Display") {
          NavigationLink("Appearance") { AppearanceSettingsView() }
        }
        Section("Location") {
          LabeledContent("Location Enabled", value: locationEnabled ? "Yes" : "No")
          Text(locationDetail).foregroundStyle(.secondary)
          if canOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: url)
          }
        }
        Section {
          if canStartLiveActivity {
            Button("Start Live Activity", action: startLiveActivity)
              .disabled(drive.setupStatus != .ready)
          }
          if drive.isDriving {
            Button("End Live Activity", action: endLiveActivity)
          }
          if drive.compactStatus == .unavailable, drive.setupStatus == .ready,
            let url = URL(string: UIApplication.openSettingsURLString)
          {
            Link("Open Settings", destination: url)
          }
        } header: {
          Text("Live Activity")
        } footer: {
          Text(liveActivityDetail)
        }
        DiagnosticsSettingsSection()
        Section {
          if let url = URL(string: "https://github.com/lunchbox-labs/compasslet") {
            Link("View Source on GitHub", destination: url)
          }
        } header: {
          Text("About")
        } footer: {
          Text("Compasslet is open source under the MIT License.")
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: close)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityFocused($closeFocused)
        }
      }
    }
    .task {
      closeFocused = true
    }
  }

  private var locationEnabled: Bool {
    drive.setupStatus == .ready || drive.setupStatus == .preciseLocationRequired
  }

  private var canStartLiveActivity: Bool {
    !drive.isDriving || drive.compactStatus == .dismissed || drive.compactStatus == .unavailable
  }

  private var liveActivityDetail: String {
    if !drive.isDriving {
      switch drive.setupStatus {
      case .ready: break
      case .unavailable: return "The Live Activity is unavailable on this device."
      default: return "Start Live Activity needs precise location. See Location above."
      }
      if drive.compactStatus == .unavailable {
        return
          "The Live Activity couldn’t start, so Compasslet isn’t using location for it. Allow Live Activities for Compasslet in the Settings app, then tap Start Live Activity."
      }
      return
        "Compasslet starts the Live Activity when you open it on CarPlay and ends it when CarPlay disconnects. If it doesn’t start, tap Start Live Activity."
    }
    switch drive.compactStatus {
    case .inactive, .starting: return "The Live Activity is starting."
    case .active where drive.startedOnPhone:
      return
        "Compasslet is using location to show your travel direction. Tap End Live Activity or dismiss the Live Activity to stop."
    case .active:
      return
        "Compasslet is using location to show your travel direction until CarPlay disconnects. End Live Activity also stops travel direction on CarPlay until you reopen Compasslet there."
    case .dismissed:
      return
        "The Live Activity was dismissed, but travel direction continues on CarPlay. Tap Start Live Activity to show it again, or End Live Activity to stop using location."
    case .unavailable:
      return
        "The Live Activity couldn’t start, but travel direction continues on CarPlay. Allow Live Activities for Compasslet in the Settings app, then tap Start Live Activity, or tap End Live Activity to stop using location."
    }
  }

  /// The tapped button leaves the form, so VoiceOver hears the outcome instead.
  private var liveActivityOutcome: String {
    if drive.compactStatus == .unavailable { return "Live Activity couldn’t start" }
    guard drive.isDriving else { return "Live Activity ended" }
    switch drive.compactStatus {
    case .active: return "Live Activity started"
    case .starting: return "Live Activity starting"
    case .inactive, .dismissed, .unavailable: return "Live Activity couldn’t start"
    }
  }

  private func startLiveActivity() {
    Task {
      await drive.startLiveActivity()
      AccessibilityNotification.Announcement(liveActivityOutcome).post()
    }
  }

  private func endLiveActivity() {
    Task {
      await drive.endDrive()
      AccessibilityNotification.Announcement(liveActivityOutcome).post()
    }
  }

  private var canOpenSettings: Bool {
    switch drive.setupStatus {
    case .denied, .servicesDisabled, .preciseLocationRequired: true
    case .ready, .permissionRequired, .restricted, .unavailable: false
    }
  }

  private var locationDetail: String {
    switch drive.setupStatus {
    case .ready:
      "Precise location is enabled for phone coordinates, elevation, and travel direction."
    case .permissionRequired: "Location permission has not been granted yet."
    case .denied:
      "Allow location while using the app for phone location details and travel direction."
    case .restricted: "Location access is restricted by this device’s settings or management."
    case .servicesDisabled:
      "Location Services is off. Turn it on in iPhone Settings under Privacy & Security."
    case .preciseLocationRequired:
      "Location is allowed, but travel direction needs Precise Location."
    case .unavailable: "Travel direction is unavailable on this device."
    }
  }
}

struct PhoneLocationReadout: View {
  @ObservedObject var location: PhoneLocationController

  var body: some View {
    VStack(spacing: 8) {
      if let fix = location.location {
        let latitude = Self.coordinate(fix.coordinate.latitude, latitude: true)
        let longitude = Self.coordinate(fix.coordinate.longitude, latitude: false)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            coordinateText(latitude)
            coordinateText(longitude)
          }
          .fixedSize(horizontal: true, vertical: true)
          VStack(spacing: 4) {
            coordinateText(latitude)
            coordinateText(longitude)
          }
        }
        .font(.subheadline).monospacedDigit()
        if let city = location.city {
          Text(city)
        }
        if let elevation = location.elevation {
          Text("\(Self.formattedElevation(elevation)) Elevation")
            .accessibilityLabel("Elevation \(Self.formattedElevation(elevation, spoken: true))")
        } else {
          Text("Elevation unavailable").foregroundStyle(.secondary)
        }
      } else {
        Text(location.approximate ? "Approximate location" : "Location unavailable")
          .foregroundStyle(.secondary)
      }
    }
  }

  /// A coordinate component in its visual notation and in words for assistive technologies.
  struct Coordinate {
    let visual: String
    let spoken: String
  }

  private func coordinateText(_ coordinate: Coordinate) -> some View {
    Text(coordinate.visual).accessibilityLabel(coordinate.spoken)
  }

  /// Degrees, minutes and seconds with a hemisphere letter, plus the same value spoken in full.
  static func coordinate(_ degrees: Double, latitude: Bool) -> Coordinate {
    let totalSeconds = Int((abs(degrees) * 3600).rounded())
    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(
      .never)
    let d = totalSeconds / 3600
    let m = totalSeconds / 60 % 60
    let s = totalSeconds % 60
    let hemisphere =
      latitude
      ? (degrees < 0 ? String(localized: "S") : String(localized: "N"))
      : (degrees < 0 ? String(localized: "W") : String(localized: "E"))
    let hemisphereName =
      latitude ? (degrees < 0 ? "south" : "north") : (degrees < 0 ? "west" : "east")
    let spokenParts = [
      latitude ? "Latitude" : "Longitude",
      "\(d) \(d == 1 ? "degree" : "degrees")",
      "\(m) \(m == 1 ? "minute" : "minutes")",
      "\(s) \(s == 1 ? "second" : "seconds")",
      hemisphereName,
    ]
    return Coordinate(
      visual:
        "\(Double(d).formatted(style))°\(Double(m).formatted(style))′\(Double(s).formatted(style))″ \(hemisphere)",
      spoken: spokenParts.joined(separator: " "))
  }

  /// Rounded elevation in the locale's unit; the spoken form names the unit in full.
  static func formattedElevation(_ meters: Double, spoken: Bool = false) -> String {
    let unit: UnitLength = Locale.current.measurementSystem == .us ? .feet : .meters
    let value = Measurement(value: meters, unit: UnitLength.meters).converted(to: unit)
    let formatter = MeasurementFormatter()
    formatter.unitOptions = .providedUnit
    formatter.unitStyle = spoken ? .long : .medium
    formatter.numberFormatter.maximumFractionDigits = 0
    return formatter.string(from: value)
  }
}
