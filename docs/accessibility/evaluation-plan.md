# Accessibility evaluation plan

This plan defines the common tasks and the evidence needed before any App Store
accessibility label is declared for Compasslet. It records how to test, not results.
A static source review is not certification: every label needs a pass on a physical
device, recorded in the matrix for the release being evaluated.

Apple's criteria: [overview](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/),
[VoiceOver](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria),
[Voice Control](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voice-control-evaluation-criteria),
[Larger Text](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria),
[Dark Interface](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/dark-interface-evaluation-criteria),
[Differentiate Without Color Alone](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria),
[Sufficient Contrast](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria),
[Reduced Motion](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria),
[Captions](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/captions-evaluation-criteria),
[Audio Descriptions](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/audio-descriptions-evaluation-criteria).

## Scope of a release

Record the exact build under test in every matrix row: app version, build number and
the commit it was built from. Evaluate only surfaces that ship in that release:

| Surface | Reachable when | Notes |
| --- | --- | --- |
| iPhone app | Always | Compass screen, Settings and its subpages, permission and error states |
| Live Activity | Only during a CarPlay drive | Lock Screen, Dynamic Island compact, minimal and expanded, and the small supplemental family. No activity exists without a drive, so its populated, waiting, slow, uncertain, unavailable, cleared and stale states all need an entitled iPhone and car or the CarPlay Simulator |
| CarPlay | Only with an entitled iPhone and car, or the CarPlay Simulator | Test while parked. The system template's constraints are not proof of accessibility |
| Apple Watch | Only if a Watch app ships in the release | An unmerged draft is not shipped support |

Ordinary timeline widgets are not part of the app and are not evaluated.

## Common tasks

Every candidate label is tested against these tasks. A label passes only when each
task can be completed with the feature on and without sighted help where the label
requires it.

1. Obtain a heading: open the app, hold the phone flat, and read direction and degrees.
2. Understand validity: tell a live heading from paused, waiting, stale, calibration,
   unavailable, denied and interrupted states, including the accuracy shown with a reading.
3. Read location details: coordinates, city and elevation, including the approximate and
   unavailable states.
4. Recover permissions: find the location status in Settings and reach the system
   Settings action when access is denied, restricted or approximate.
5. Configure appearance: change readout visibility, text size, tick density, label
   placement and rotation for the global defaults and for one surface.
6. Navigate Settings: open it from the compass screen, move between Display, Location and
   Diagnostics, export diagnostics, and return to the compass with focus restored.
7. Understand travel surfaces: read the Live Activity as a last recorded travel direction
   with its sample time, and recognize its waiting, slow, uncertain, unavailable, cleared
   and stale states.

## Evidence to record

Every matrix row records the device model, iOS version, build and commit, the relevant
system settings, the steps taken and a pass or fail with notes. Capture the states that
need setup, not just live sensor data: no heading (Simulator or a shielded device),
stale heading, denied location, Location Services off, approximate location, and a
Live Activity whose reading has been cleared or gone stale.

Automated checks where tooling supports them:

- Xcode Accessibility Inspector audit of the compass screen, Settings and each
  Appearance subpage, in light and dark, at the default and the largest accessibility size.
- Accessibility Inspector's Color Contrast Calculator for the readout, status text,
  accuracy line, dial labels and the red north marker, in light and dark and with Bold
  Text, Increase Contrast and Reduce Transparency on.
- An XCUITest accessibility audit (`performAccessibilityAudit`) if a UI test target is
  added; the Xcode project has hosted unit-test targets and no UI test target.

Manual VoiceOver and Voice Control sessions remain required evidence; automation does not
replace them.

Supplemental checks with Switch Control and Full Keyboard Access are worth recording in
the notes of the VoiceOver and Voice Control tables. They are not App Store labels in this
list and no label is declared from them.

## Candidate labels

Fill one row per task and surface. Copy the table for each release. Each label lists the
change it depends on; evidence recorded against a build without that change does not
count toward the label.

Captions and Audio Descriptions do not apply: the app has no media playback. Do not
declare them and do not add unrelated controls to earn them. Reassess if media is added.

### VoiceOver

Prerequisite: the VoiceOver changes from #77. Settings: VoiceOver on. Also note reading
order, whether heading changes move focus or cause unsolicited announcements, and
whether every direction is spoken as a full word.

| Task | Surface | Device | iOS | Build / commit | Settings | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

### Voice Control

Prerequisite: none beyond the release build. Settings: Voice Control on, with overlay
names shown. Confirm the Settings button, Done buttons, toggles, pickers, slider and Open
Settings all have speakable names, and that Settings opens by its button without the edge
swipe.

| Task | Surface | Device | iOS | Build / commit | Settings | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

### Larger Text

Prerequisite: the Larger Text changes from #78. Settings: Larger Accessibility Sizes on,
tested at the default size, AX3 and AX5, with and without Bold Text, on the smallest
supported iPhone. Apple's criteria treat AX3 as the 200 percent point, so the primary
reading must be whole and readable there and at AX5. The compass screen collapses to one
essential reading at accessibility sizes and sends the remaining details to Settings;
confirm those details are still reachable and readable at AX3 and AX5. Check each Live
Activity family in its real bounds.

| Task | Surface | Device | iOS | Build / commit | Text size | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

### Dark Interface

Prerequisite: none beyond the release build. Settings: Dark appearance, then Automatic.
Check launch, permission and error states, Settings, the export sheet and the Live
Activity for bright flashes or illegible content. Do not infer a pass from color
constants.

| Task | Surface | Device | iOS | Build / commit | Appearance | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

### Differentiate Without Color Alone

Prerequisite: the north marker and contrast changes from #79. Settings: Differentiate
Without Color on and Color Filters set to Grayscale. On iPhone, check both rotation
choices with cardinal labels hidden and with both center readouts hidden, and confirm
north and each status remain identifiable. The Live Activity is text only.

| Task | Surface | Device | iOS | Build / commit | Appearance choices | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

### Sufficient Contrast

Prerequisite: the north marker and contrast changes from #79. Measure with the Color
Contrast Calculator in light and dark, then with Increase Contrast and Reduce
Transparency. Record the ratio for information-bearing text and marks; decorative
strokes are noted separately.

| Element | Surface | Device | iOS | Build / commit | Settings | Ratio | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

### Reduced Motion

Prerequisite: the reduced-motion changes from #80. Settings: Reduce Motion on and off.
Test rapid turns, crossing north, noisy input near metal, opening and closing Settings,
and Live Activity updates where the app controls the transition. Record whether the dial
presentation or any override is explained to the user.

| Task | Surface | Device | iOS | Build / commit | Reduce Motion | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

## Declaring labels

Declare a label only for the devices and surfaces that passed every common task. Keep
this record and the in-app Accessibility page proposed in #81, once it ships, in step:
when a result changes, update both. Editing App Store Connect metadata is a separate
release action and is not part of running this plan.
