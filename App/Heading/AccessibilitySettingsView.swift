import SwiftUI

/// Describes how this version is designed to behave with accessibility features and points to
/// the existing controls that affect it. System features are explained, never duplicated as
/// in-app switches.
struct AccessibilitySettingsView: View {
  let close: () -> Void

  var body: some View {
    Form {
      Section {
        Text(
          "The iPhone compass shows the magnetic heading of the top of your phone while the app is open. Readings older than five seconds are removed rather than kept."
        )
        Text(
          "CarPlay and the Live Activity show the vehicle’s direction of travel relative to true north: where the car moved, not where the phone or the car points. CarPlay shows the most recent sampled course with its sample time and removes it when input stops; it is a snapshot updated at most every ten seconds, drawn by Apple’s list template with the system’s layout and text sizes and no controls. The Live Activity keeps the last accepted reading, and its card shows the sample time. Dismissing the Live Activity does not stop the drive."
        )
      } header: {
        Text("Two kinds of reading")
      }
      Section {
        Text(
          "The heading is spoken with its degrees, direction name and accuracy. Status text explains paused, waiting, stale, calibration, unavailable, denied and interrupted states, and the denied state offers Open Settings."
        )
        Text(
          "Settings opens as its own screen. Done, on any Settings page, or the Escape gesture from the main Settings screen returns to the compass with focus on the Settings button; Back returns to the previous page."
        )
        Text(
          "Live Activity readings are spoken as a last recorded travel direction, with the sample time where it is shown, or as the current status."
        )
      } header: {
        Text("VoiceOver and Voice Control")
      } footer: {
        Text(
          "Buttons, toggles, pickers and the text size slider have spoken names matching their labels; the menu button is named Settings. VoiceOver and Voice Control are turned on in iPhone Settings under Accessibility."
        )
      }
      Section {
        NavigationLink("Appearance") { AppearanceSettingsView() }
      } header: {
        Text("Text size")
      } footer: {
        Text(
          "Interface text follows the system text size. The compass readout follows it too, or uses a custom size chosen in Appearance. At the largest sizes the compass screen keeps one readable reading; location details and status remain available here in Settings, which scrolls."
        )
      }
      Section {
        Text(
          "With Reduce Motion on, Settings appears and closes without animation, and heading smoothing is turned off so the dial moves only when the sensor reports a changed heading. Choosing Rotate arrow in Appearance keeps the dial still and moves only the arrow."
        )
      } header: {
        Text("Motion")
      }
      Section {
        Text(
          "Colors follow the system light and dark appearance. Direction and degrees are shown as text, so a reading does not depend on color. North is red on the dial and is also labeled N; with Rotate arrow it also stays at the top."
        )
      } header: {
        Text("Color and contrast")
      } footer: {
        Text(
          "Hiding the cardinal labels in Appearance leaves color as the rotating dial’s north cue. Keep the labels or the readout visible if you rely on shape or text."
        )
      }
      Section {
        Text(
          "System accessibility features are controlled by iPhone, not by this app. These notes describe how this version is designed to behave; they are not App Store accessibility labels."
        )
      }
    }
    .navigationTitle("Accessibility")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done", action: close).frame(minWidth: 44, minHeight: 44)
      }
    }
  }
}
