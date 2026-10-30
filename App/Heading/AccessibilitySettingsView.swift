import SwiftUI
import UIKit

/// Describes the accessibility behavior checked in this version and points to the existing
/// controls that affect it. System features are explained, never duplicated as in-app switches.
struct AccessibilitySettingsView: View {
  var body: some View {
    Form {
      Section {
        Text(
          "The iPhone compass shows the magnetic heading of the top of your phone while the app is open. Readings older than five seconds are removed rather than kept."
        )
        Text(
          "CarPlay and the Live Activity show the vehicle’s last recorded direction of travel relative to true north. That is where the car moved, not where the phone or the car points, and it is always shown with its sample time or age."
        )
      } header: {
        Text("Two kinds of reading")
      }
      Section {
        Text(
          "The heading is spoken with its degrees, direction name and accuracy. Status text explains paused, waiting, stale, calibration, unavailable and denied states, and the denied state offers Open Settings."
        )
        Text(
          "Settings opens as its own screen. Done or the Escape gesture returns to the compass with focus on the Settings button."
        )
        Text(
          "Live Activity readings are spoken as a last recorded travel direction with their sample time, or as their current status."
        )
      } header: {
        Text("VoiceOver and Voice Control")
      } footer: {
        Text(
          "Buttons, toggles, pickers and the text size slider use their visible names. VoiceOver and Voice Control are turned on in iPhone Settings under Accessibility."
        )
      }
      Section {
        NavigationLink("Appearance") { AppearanceSettingsView() }
      } header: {
        Text("Text size")
      } footer: {
        Text(
          "Interface text follows the system text size. The compass readout follows it too, or uses a custom size chosen in Appearance. At the largest sizes the compass screen keeps one readable reading and moves the remaining details into Settings, which scrolls."
        )
      }
      Section {
        Text(
          "With Reduce Motion on, Settings fades in instead of sliding, and heading smoothing is turned off so the dial moves only when the sensor reports a changed heading. Choosing Rotate arrow in Appearance keeps the dial still and moves only the arrow."
        )
      } header: {
        Text("Motion")
      }
      Section {
        Text(
          "Colors follow the system light and dark appearance. Direction and degrees are shown as text, so a reading does not depend on color. North is red on the dial and is also labeled N."
        )
      } header: {
        Text("Color and contrast")
      } footer: {
        Text(
          "Hiding the cardinal labels in Appearance leaves color as the dial’s north cue. Keep the labels or a center readout visible if you rely on shape or text."
        )
      }
      Section {
        Text(
          "Live Activity: the last travel direction with its sample time. Dismissing it does not stop the drive."
        )
        Text(
          "CarPlay: Apple’s list template with the system’s layout, text sizes and controls. The dial is a snapshot updated at most every ten seconds."
        )
      } header: {
        Text("Other surfaces")
      }
      Section {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          Link("Open Settings", destination: url)
        }
      } footer: {
        Text(
          "System accessibility features are controlled by iPhone, not by this app. These notes describe behavior checked in this version; they are not App Store accessibility labels."
        )
      }
    }
    .navigationTitle("Accessibility")
    .navigationBarTitleDisplayMode(.inline)
  }
}
