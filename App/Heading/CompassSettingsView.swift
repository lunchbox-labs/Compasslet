import SwiftUI
import UIKit

struct CompassSettingsView: View {
  @ObservedObject var drive: DriveSessionController
  @Environment(\.dismiss) private var dismiss

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
        DiagnosticsSettingsSection()
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
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
    case .ready: "Precise location is enabled for CarPlay travel direction."
    case .permissionRequired: "Location permission has not been granted yet."
    case .denied: "Allow location while using the app to enable CarPlay travel direction."
    case .restricted: "Location access is restricted by this device’s settings or management."
    case .servicesDisabled:
      "Location Services is off. Turn it on in iPhone Settings under Privacy & Security."
    case .preciseLocationRequired:
      "Location is allowed, but CarPlay travel direction needs Precise Location."
    case .unavailable: "Travel direction is unavailable on this device."
    }
  }
}
