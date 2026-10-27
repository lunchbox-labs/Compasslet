# CarPlay Compass

A native SwiftUI compass planned for **iOS 27 and later**. The repository currently
contains development tooling and the portable CompassCore package; there is no app project yet.

## Swift style

Use **Swift 6.4.1**, including its bundled **swift-format 6.4.1**, on Linux or macOS.
Install the toolchain from [Swift.org](https://www.swift.org/install/), and make
`swift-format` available on `PATH`. The script checks its exact version. Xcode and
Apple SDK selection are separate from this formatter pin.

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

## Build and test status

There are no application build or test commands until targets and schemes exist.
Linux can validate portable Swift modules; SwiftUI, CoreLocation, WidgetKit, and
CarPlay require macOS and compatible Xcode/Apple SDKs. Formatting is not a compile
or test gate.

CompassCore is a dependency-free Swift package using Swift 6 language mode,
warnings as errors, and Swift Testing. Run `swift build --jobs 4 -c release` and
`swift test --jobs 4` with Swift 6.4.1 to validate it on Linux or macOS.

The iOS app will need a shared Xcode scheme and an explicit iOS 27+ Simulator test
destination. Device heading, sensor accuracy, lifecycle behavior, and CarPlay
integration also need physical-device validation. No signing or entitlement setup
is included in this foundation.

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
