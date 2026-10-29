import SwiftUI
import UIKit

/// Phone-only explanation and controls; an eligible CarPlay activation starts acquisition.
struct CarPlaySetupView: View {
  @ObservedObject var drive: DriveSessionController
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("CarPlay travel compass").font(.headline)
      Text(
        "CarPlay uses your vehicle’s travel direction relative to true north. Allow precise location while using Compass before connecting. Location runs only during a drive, including while using Maps. No position or route history is saved."
      )
      Text(status).foregroundStyle(.secondary)
      if drive.setupStatus == .permissionRequired {
        Button("Allow location on this phone") {
          drive.requestPhoneAuthorization(isForeground: scenePhase == .active)
        }
      }
      if drive.setupStatus != .ready,
        let url = URL(string: UIApplication.openSettingsURLString)
      {
        Link("Open Settings", destination: url)
      }
      if drive.isDriving {
        Button("End drive", role: .destructive) { Task { await drive.endDrive() } }
      }
    }
    .task { await drive.prepare() }
  }

  private var status: String {
    switch drive.setupStatus {
    case .permissionRequired: "Allow location on your phone to set up CarPlay."
    case .preciseLocationRequired: "Enable Precise Location in Settings."
    case .unavailable: "Travel direction is unavailable on this device."
    case .ready: drive.isDriving ? "Drive active" : "Ready for an active CarPlay connection."
    }
  }
}
