import CompassCore
import SwiftUI
import UIKit

struct CompassSettingsView: View {
  let drive: DriveSessionController
  let showTour: () -> Void
  /// Present only in TestFlight test builds, so testers can tell which build they have.
  var testBuild = TestBuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])
  @Environment(\.dismiss) private var dismiss
  @AccessibilityFocusState private var closeFocused: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section("Display") {
          NavigationLink("Appearance") { AppearanceSettingsView() }
        }
        Section("Driving") {
          NavigationLink("Live Activity") { LiveActivitySettingsView() }
        }
        Section("Location") {
          LabeledContent("Location Enabled") {
            Text(drive.setupStatus.locationEnabledValue).foregroundStyle(.primary)
          }
          Text(drive.setupStatus.settingsDetail).foregroundStyle(.primary)
          if drive.setupStatus == .permissionRequired {
            Button("Enable Location") { drive.askForLocationPermission() }
              .foregroundStyle(.tint)
          } else if drive.setupStatus.canOpenSettings,
            let url = URL(string: UIApplication.openSettingsURLString)
          {
            Link("Open Settings", destination: url).foregroundStyle(.tint)
          }
        }
        Section("Help") {
          Button("Show Welcome Tour", action: showTour)
        }
        DiagnosticsSettingsSection()
        Section {
          if let url = SourceRepository.url {
            Link("View Source on GitHub", destination: url)
              // Links draw in the system blue (3.6:1 on these rows), not the accent, unless told.
              .foregroundStyle(.tint)
          }
        } header: {
          Text("About")
        } footer: {
          Text("Compasslet is open source under the MIT License.")
        }
        if let testBuild {
          Section {
            LabeledContent("Version") {
              Text(testBuild.versionAndBuild).foregroundStyle(.primary).textSelection(.enabled)
            }
            Link(destination: testBuild.commitURL) {
              LabeledContent {
                // The accent, as on the app's other links; links otherwise draw in the system
                // blue, 3.6:1 on these rows.
                Text(testBuild.shortCommit).foregroundStyle(.tint)
              } label: {
                // A fixed colour, since the relative .primary would take the link's colour.
                Text("Commit").foregroundStyle(Color.primary)
              }
            }
            .accessibilityLabel("Commit")
            .accessibilityValue(Text(testBuild.shortCommit).speechSpellsOutCharacters())
            .accessibilityHint("Opens the commit on GitHub.")
            .accessibilityAction(named: "Copy Commit") { copyCommit(testBuild) }
            .contextMenu {
              Button("Copy Commit", systemImage: "doc.on.doc") { copyCommit(testBuild) }
            }
          } header: {
            Text("Test Build")
          } footer: {
            Text("For TestFlight testing only.")
          }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .frame(minWidth: 44, minHeight: 44)
            // Filled with the accent: white on the light-mode plum, dark on the dark-mode pink,
            // where white would be only 2.14:1. The style is explicit so the fill doesn't
            // depend on how the toolbar chooses to draw a confirming button.
            .buttonStyle(.glassProminent)
            .foregroundStyle(Color.confirmActionLabel)
            .accessibilityFocused($closeFocused)
        }
      }
    }
    .task {
      closeFocused = true
    }
  }

  /// Copies the full SHA, which the row shortens, and tells VoiceOver it worked.
  private func copyCommit(_ testBuild: TestBuildIdentity) {
    UIPasteboard.general.string = testBuild.commit
    AccessibilityNotification.Announcement("Commit copied").post()
  }
}

struct PhoneLocationReadout: View {
  let location: PhoneLocationController

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
          Text("Elevation unavailable").foregroundStyle(.primary)
        }
      } else {
        Text(location.approximate ? "Approximate location" : "Location unavailable")
          .foregroundStyle(.primary)
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
