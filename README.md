# CarPlay Compass

A native SwiftUI **iOS 27+ iPhone compass** showing the direction the top of your
phone points relative to magnetic north. It works while stationary, uses no travel
course, and requests no location authorization or background tracking. Nearby
magnets and metal can affect its accuracy.

## Run the app

Open `Compass.xcodeproj` in **Xcode 27.1** and choose the shared **Compass** scheme.
Select an iPhone simulator or your iPhone, then Run. For a physical device, select
your own development team in Signing & Capabilities; no team or credentials are
checked into this project. The interface supports portrait orientation.

Simulator has no heading sensor and displays an unavailable explanation. Use an
actual iPhone for live compass readings. The app removes invalid readings and
readings older than five seconds, and pauses when it leaves the foreground.
Magnetic heading does not require requesting raw location or true north.

From macOS with Xcode 27.1 selected:

```sh
xcodebuild -project Compass.xcodeproj -scheme Compass \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
bash scripts/test-ios
```

The test script chooses an installed, available iOS 27+ iPhone simulator. It runs
hosted state tests using injected sensor events and time; it does not fabricate
production sensor readings. CI builds the actual app and runs this shared scheme.

On a physical iPhone, check that there is no location permission prompt, that the
heading follows the phone’s top while stationary, and that crossing north does
not spin the needle around the dial. Check calibration away from metal and
magnets, leaving and returning to the foreground, and recovery after an
interruption. Check actual denied/restricted service behavior if system settings
produce it; an undetermined location authorization alone does not block magnetic
heading. Also check VoiceOver, larger Dynamic Type, light/dark appearance, and
Reduce Motion. Device sensor accuracy and these physical-device checks remain
separate from simulator state tests. There is no CarPlay integration in this app.

## Swift style

Use **Swift 6.4.1**, including its bundled **swift-format 6.4.1**, on Linux.
Install the toolchain from [Swift.org](https://www.swift.org/install/), and make
`swift-format` available on `PATH`. The script checks its exact version. This
patch is a Linux release; Xcode 27.1 provides Swift 6.4 for the native app.
On macOS, optionally run the pinned formatter with Docker:

```sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.4.1 bash scripts/swift-style check
```

Xcode build and Run do not require Docker.

From the repository root:

```sh
bash scripts/swift-style check
bash scripts/swift-style format
```

`check` reports formatting and lint findings as errors. `format` rewrites Swift
files; run `check` afterward because formatting cannot fix every lint finding.
Both commands include tracked Swift files and nonignored untracked Swift files,
exclude symbolic links, and return status 2 when there are no Swift files to
process. Keep generated output and vendored sources untracked and ignored.

The configuration follows the [Swift profile in KrishRVH/standards](https://github.com/KrishRVH/standards/tree/main/Swift):
two-space indentation, a 100-column target, documentation checks, and diagnostics
for force unwraps, force tries, and implicitly unwrapped optionals. Native rule
exceptions still apply. SwiftLint is not required.

## Portable core

CompassCore is a dependency-free Swift package using Swift 6 language mode,
warnings as errors, and Swift Testing. On Linux with Swift 6.4.1, run
`swift build --jobs 4 -c release` and `swift test --jobs 4`.
Apple UI and CoreLocation compilation require macOS and Xcode; formatting and
Linux syntax checks do not validate Apple SDK integration.

## CompassCore usage

`CompassAngle(degrees:)` normalizes finite angles into `0..<360`. Its
`shortestDelta(to:)` returns the signed shortest rotation, with exact half-turns
always represented by +180 degrees.

`CompassSample(degrees:source:reference:accuracy:timestamp:)` accepts sensor angles
in `0...360`, nonnegative finite accuracy, and finite timestamps. Negative sensor
sentinels are rejected. Use `.deviceHeading` for device orientation and
`.vehicleCourse` for direction of travel; north references are `.magnetic` and
`.trueNorth`. A zero-degree reading is valid.

Call `isFresh(now:maximumAge:)` with an injected clock and finite nonnegative age
limit. The age boundary is inclusive; future readings are rejected.
`CompassSmoother(fraction:)` accepts a fraction in `(0, 1]`. Pass validated samples
to `update(_:now:maximumAge:)`; pass nil when a sensor reading is invalid. The
smoother crosses north by the shortest rotation and preserves the latest sample's
metadata. Missing/stale input clears its state. Changes in source or north
reference, stale gaps, and reversed timestamps start a new sequence. Use `reset()`
when ending a sensor session.
