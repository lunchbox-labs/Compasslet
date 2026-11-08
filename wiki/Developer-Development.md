# Development

Open `Compass.xcodeproj` in Xcode 27.1 and choose the Compass scheme. Use your own
signing team for a physical device. Simulator has no heading sensor; use an iPhone
to verify real readings. The interface supports portrait orientation.

## Checks

The build and test commands, with the toolchain each needs, are in the
[Commands](https://github.com/lunchbox-labs/compasslet/blob/main/AGENTS.md#commands)
section of `AGENTS.md`, which mirrors what CI runs.

`bash scripts/swift-style format` applies formatting; run `check` again afterwards.
The formatter includes tracked and nonignored untracked Swift files, excluding
symlinks. Generated and vendored output should remain ignored. Xcode uses Swift
6.4; Apple SDK integration still requires native checks.

## Device validation

Before release, verify stationary phone heading, crossing north, both display
styles, foreground recovery and unavailable-sensor behavior. Check VoiceOver,
large Dynamic Type with Bold Text on the smallest supported iPhone, contrast,
light/dark appearance and Reduce Motion. Reduce Motion normally replaces the dial
with text; Keep the Dial uses discrete steps rather than continuous rotation.

CarPlay requires Apple's driving-task approval and matching external provisioning;
the checked-in entitlement and unsigned builds do not establish approval. Validate
an entitled iPhone and car while parked, including locked-phone startup, switching
to Maps, disconnect, stopped/reverse travel, poor GPS, permission/precision loss,
Live Activity dismissal, accessibility and battery/thermal behavior. Confirm that
retained activity samples preserve their time and clear on interruption or teardown.
iOS controls rendering; simulator success cannot establish in-car update cadence.

## Reading policies

Phone magnetic headings expire after five seconds and acquisition pauses outside
the foreground. Full-screen CarPlay samples update at most every ten seconds;
invalid or older-than-five-second input clears the bearing. Reverse travel is
travel direction, not vehicle orientation.

The Live Activity retains the last valid travel sample through stops within the
same drive. Explicit interruption clears it; disconnect, permission/service loss
or the eight-hour limit clears and ends it. Dismissal removes only the activity
for that drive. Changed readings update at most once per second; unchanged readings
need no heartbeat. No prior-drive reading is restored.

## CompassCore

CompassCore contains angle normalization, sample validation, freshness checks and
shortest-path smoothing. Keep device heading and vehicle course sources distinct,
and preserve their magnetic/true-north references and original timestamps.
Invalid input or a stale gap must not be presented as a new reading. See the public
API documentation and behavioral tests in `Sources` and `Tests` when changing these
contracts.

[State Machines](Developer-State-Machines) maps the states and transitions that enforce the
reading policies above. Release maintainers use [Publishing](Developer-Publishing).

## Editing this wiki

These pages live in the repository's
[`wiki` folder](https://github.com/lunchbox-labs/compasslet/tree/main/wiki). Change them there
in a pull request; the Wiki workflow publishes the folder when the change merges to `main`, and
replaces any edit made directly on the wiki.
