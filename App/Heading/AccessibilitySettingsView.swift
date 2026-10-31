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
          "CarPlay and the Live Activity show the vehicle’s direction of travel relative to true north: where the car moved, not where the phone or the car points."
        )
        Text(
          "CarPlay shows the most recent sampled course with its sample time and removes it when input stops. It is a snapshot updated at most every ten seconds, drawn by Apple’s list template with the system’s layout and text sizes and no controls."
        )
        Text(
          "The Live Activity keeps the last accepted reading, and its card shows the sample time. Dismissing the Live Activity does not stop the drive."
        )
      } header: {
        Text("Two kinds of reading")
      }
      Section {
        Text(
          "The heading is spoken with its degrees, direction name and accuracy. Status text explains paused, waiting, stale, calibration, unavailable, denied and interrupted states, and the denied state offers Open Settings."
        )
        Text(
          "Settings opens as its own screen. Done, where shown, or the Escape gesture from the main Settings screen returns to the compass with focus on the Settings button; Back returns to the previous page."
        )
        Text(
          "Live Activity readings are spoken as a last recorded travel direction, with the sample time where it is shown, or as the current status."
        )
      } header: {
        Text("VoiceOver and Voice Control")
      } footer: {
        Text(
          "Controls have spoken names; the menu button is named Settings. VoiceOver and Voice Control are turned on in iPhone Settings under Accessibility."
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
          "With Reduce Motion on, Settings appears and closes without animation, and the compass shows a steady direction and degrees reading instead of the rotating dial. Appearance › Reduce Motion can keep the dial instead; it then moves in steps of about four degrees, so a settled reading can differ from the sensor by up to four degrees. Choosing Rotate arrow keeps the dial still and moves only the arrow."
        )
      } header: {
        Text("Motion")
      }
      Section {
        Text(
          "Colors follow the system light and dark appearance. Direction and degrees are shown as text, so a reading does not depend on color. North is marked on the dial by a pointed rim tick that is longer than the other ticks, in red, and labeled N; with Rotate arrow it also stays at the top. With Increase Contrast on, the dial’s labels, rim and ticks use stronger colors and strokes."
        )
      } header: {
        Text("Color and contrast")
      } footer: {
        Text(
          "Hiding the cardinal labels in Appearance keeps the pointed north tick, so north stays identifiable by shape as well as color."
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
