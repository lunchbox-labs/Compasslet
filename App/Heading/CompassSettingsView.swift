import SwiftUI
import UIKit

struct CompassSettingsView: View {
  @ObservedObject var drive: DriveSessionController
  @ObservedObject var location: PhoneLocationController
  let headingStatus: HeadingController.Status
  var showLocationDetails = false
  let close: () -> Void
  @State private var locationDetailsPresented = false
  @AccessibilityFocusState private var closeFocused: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section("Display") {
          NavigationLink("Appearance") { AppearanceSettingsView() }
        }
        Section("Location") {
          NavigationLink("Location details") { locationDetails }
          LabeledContent("Location Enabled", value: locationEnabled ? "Yes" : "No")
          Text(locationDetail).foregroundStyle(.secondary)
          if canOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: url)
          }
        }
        DiagnosticsSettingsSection()
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $locationDetailsPresented) { locationDetails }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: close)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityFocused($closeFocused)
        }
      }
    }
    .task {
      locationDetailsPresented = showLocationDetails
      closeFocused = true
    }
  }

  private var locationDetails: some View {
    Form {
      Section("Current location") {
        PhoneLocationReadout(location: location)
      }
      if headingStatus != .live {
        Section(headingStatus.title) {
          Text(headingStatus.detail)
          if headingStatus == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: url)
          }
        }
      }
    }
    .navigationTitle("Location details")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done", action: close).frame(minWidth: 44, minHeight: 44)
      }
    }
  }

  private var locationEnabled: Bool {
    drive.setupStatus == .ready || drive.setupStatus == .preciseLocationRequired
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
}

struct PhoneLocationReadout: View {
  @ObservedObject var location: PhoneLocationController

  var body: some View {
    VStack(spacing: 8) {
      if let fix = location.location {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            Text(coordinate(fix.coordinate.latitude, latitude: true))
            Text(coordinate(fix.coordinate.longitude, latitude: false))
          }
          .fixedSize(horizontal: true, vertical: true)
          VStack(spacing: 4) {
            Text(coordinate(fix.coordinate.latitude, latitude: true))
            Text(coordinate(fix.coordinate.longitude, latitude: false))
          }
        }
        .font(.subheadline).monospacedDigit()
        if let elevation = location.elevation {
          Text("\(formattedElevation(elevation)) Elevation")
        } else {
          Text("Elevation unavailable").foregroundStyle(.secondary)
        }
      } else {
        Text(location.approximate ? "Approximate location" : "Location unavailable")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func coordinate(_ degrees: Double, latitude: Bool) -> String {
    let totalSeconds = Int((abs(degrees) * 3600).rounded())
    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(
      .never)
    let d = Double(totalSeconds / 3600).formatted(style)
    let m = Double(totalSeconds / 60 % 60).formatted(style)
    let s = Double(totalSeconds % 60).formatted(style)
    let hemisphere =
      latitude
      ? (degrees < 0 ? String(localized: "S") : String(localized: "N"))
      : (degrees < 0 ? String(localized: "W") : String(localized: "E"))
    return "\(d)°\(m)′\(s)″ \(hemisphere)"
  }

  private func formattedElevation(_ meters: Double) -> String {
    let unit: UnitLength = Locale.current.measurementSystem == .us ? .feet : .meters
    let value = Measurement(value: meters, unit: UnitLength.meters).converted(to: unit)
    let formatter = MeasurementFormatter()
    formatter.unitOptions = .providedUnit
    formatter.numberFormatter.maximumFractionDigits = 0
    return formatter.string(from: value)
  }
}
