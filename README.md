# CarPlay Compass

A native SwiftUI compass planned for **iOS 27 and later**. The repository currently
contains development tooling only; there is no app project or test target yet.

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

The intended test foundation is a dependency-free Swift package for angle and
reading-validity logic, using Swift Testing. Use Swift 6 language mode (complete
concurrency checking) and warnings as errors for first-party app and test targets.
Keep UI state on the main actor and inject time into freshness checks. Add package
build/test commands and CI alongside the first meaningful model tests; do not add
an empty test target or claim a successful zero-test run.

The iOS app will need a shared Xcode scheme and an explicit iOS 27+ Simulator test
destination. Device heading, sensor accuracy, lifecycle behavior, and CarPlay
integration also need physical-device validation. No signing or entitlement setup
is included in this foundation.
