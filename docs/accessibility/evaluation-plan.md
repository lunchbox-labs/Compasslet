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
[Reduced Motion](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria).

## Scope of a release

Record the exact build under test in every matrix row: app version, build number and
the commit it was built from. Evaluate only surfaces that ship in that release:

| Surface | Included when | Notes |
| --- | --- | --- |
| iPhone app | Always | Compass screen, Settings and its subpages, permission and error states |
| Live Activity | Always | Lock Screen, Dynamic Island compact, minimal and expanded, small supplemental family |
| CarPlay | Only with an entitled device and car or CarPlay Simulator | Test while parked. The system template's constraints are not proof of accessibility |
| Apple Watch | Only if a Watch app ships in the release | An unmerged draft is not shipped support |

Captions and Audio Descriptions do not apply: the app has no media playback. Do not
declare them and do not add unrelated controls to earn them. Reassess if media is added.

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
   with its sample time, and recognize its waiting, slow, uncertain, unavailable and
   stale states.

## Evidence to record

For each matrix row record device model, iOS version, build and commit, the relevant
system settings, the steps taken and a pass or fail with notes. Capture the states that
need setup, not just live sensor data: no heading (Simulator or a shielded device),
stale heading, denied location, Location Services off, approximate location, and a
Live Activity whose reading has been cleared or gone stale.

Automated checks where tooling supports them:

- Xcode Accessibility Inspector audit of the compass screen, Settings and each
  Appearance subpage, in light and dark, at default and the largest accessibility size.
- Accessibility Inspector color contrast measurement for the readout, status text,
  accuracy line, dial labels and the red north marker, in light and dark and with Bold
  Text, Increase Contrast and Reduce Transparency on.
- An XCUITest accessibility audit (`performAccessibilityAudit`) if a UI test target is
  added; the repository currently has hosted unit tests only.

Manual VoiceOver and Voice Control sessions remain required evidence; automation does not
replace them.

## Candidate labels

Fill one row per task and surface. Copy the table for each release.

### VoiceOver

Settings: VoiceOver on. Also note reading order, whether heading changes move focus or
cause unsolicited announcements, and whether every direction is spoken as a full word.

| Task | Surface | Device | iOS | Build / commit | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

### Voice Control

Settings: Voice Control on, with overlay names shown. Confirm the Settings button, Done
buttons, toggles, pickers, slider and Open Settings all have speakable names, and that the
Settings drawer can be opened without the edge swipe.

| Task | Surface | Device | iOS | Build / commit | Steps | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

### Larger Text

Settings: Larger Accessibility Sizes on, tested at the default size, AX3 and AX5, with
and without Bold Text, on the smallest supported iPhone. Confirm the primary reading
reaches at least 200 percent or the system maximum, nothing is clipped or overlapped,
and each Live Activity family stays readable in its real bounds.

| Task | Surface | Device | iOS | Build / commit | Text size | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

### Dark Interface

Settings: Dark appearance, then Auto switching. Check launch, permission and error
states, Settings, the export sheet and the Live Activity for bright flashes or
illegible content. Do not infer a pass from color constants.

| Task | Surface | Device | iOS | Build / commit | Appearance | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

### Differentiate Without Color Alone

Settings: Differentiate Without Color on and Color Filters set to Grayscale. Check every
dial style with cardinal labels hidden and with both center readouts hidden, and confirm
north and each status remain identifiable.

| Task | Surface | Device | iOS | Build / commit | Appearance choices | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

### Sufficient Contrast

Measure with Accessibility Inspector in light and dark, then with Increase Contrast and
Reduce Transparency. Record the ratio for information-bearing text and marks; decorative
strokes are noted separately.

| Element | Surface | Appearance | Settings | Build / commit | Ratio | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

### Reduced Motion

Settings: Reduce Motion on and off. Test rapid turns, crossing north, noisy input near
metal, opening and closing Settings, and Live Activity updates where the app controls
the transition. Record whether the dial presentation or any override is
explained to the user.

| Task | Surface | Device | iOS | Build / commit | Reduce Motion | Result | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

## Declaring labels

Declare a label only for the devices and surfaces that passed every common task. Keep
the in-app Accessibility page and this record in step: when a result changes, update
both. Editing App Store Connect metadata is a separate release action and is not part
of running this plan.
