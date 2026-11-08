# Agent instructions

Before working in this repository, read and follow these shared Lunchbox Labs documents:

- [Common agent guidance](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/common.md)
- [Workflow conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/workflows.md)
- [iOS app conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/ios-apps.md)
- [Agent tooling conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/agent-tooling.md)

Read these documents explicitly; GitHub does not automatically inherit them into this repository.

## Commands

Run these from the repository root. The app targets iOS 27.0 and builds with Xcode 27.1
(`Compass.xcodeproj`, `Compass` scheme). On macOS with Xcode 27.1 selected, build and test
the app on an available iOS 27+ iPhone simulator:

```sh
bash scripts/test-ios
```

The `CompassCore` package and formatting checks need Swift 6.4.1 and its bundled
swift-format 6.4.1; CI runs them on Linux in the `swift:6.4.1` container:

```sh
bash scripts/swift-style check   # or format, to apply the formatting
swift build --jobs 4 -c release
swift test --jobs 4
```

The helper scripts have offline tests that need Python 3, Git and OpenSSL, but no Apple
credentials or network access:

```sh
python3 -m unittest discover -s scripts/tests -v
```

The workflow event-condition tests need Node and network access for `npm ci`:

```sh
npm ci --prefix scripts/tests/workflows --ignore-scripts --no-audit --no-fund
npm test --prefix scripts/tests/workflows
```

Simulator tests inject heading and location input, so they don't validate the physical sensors
or in-car CarPlay operation. Physical-device checks are on the
[Development](https://github.com/lunchbox-labs/compasslet/wiki/Developer-Development#device-validation)
wiki page.

## UI capitalization

Use title case for visible headings, navigation titles, short control labels and
label-style captions. Capitalize the first and last words and content words; keep
articles, coordinating conjunctions and short prepositions (for example, “a”,
“the”, “and”, “of”, “to” and “per”) lowercase unless first or last. Preserve product
names such as iPhone, CarPlay and VoiceOver. Examples: “Custom Text Size”,
“Minor Ticks per Quarter” and “Keep the Dial”.

Keep explanations, questions, dynamic status messages and spoken accessibility
prose in sentence case. When prose names a control, use that control’s exact label.
Accessible control names should match their visible labels. Do not title-case
identifiers or apply automatic casing to localized strings.

## Contributor workflows

For user-facing copy, navigation, settings, or behavior changes, delegate an
independent pass to `user-experience-reviewer` using
[the user experience procedure](.agents/skills/user-experience-review/SKILL.md).
For changes to accessibility, appearance/layout, location lifecycle, CarPlay, or
Live Activities, also use `accessibility-platform-reviewer` with
[the platform procedure](.agents/skills/accessibility-platform-review/SKILL.md).
Use only the applicable roles; contributor tooling or unrelated internal changes
do not need these product reviews.

Give reviewers the diff/base, intended user task, and available screenshots or
runtime/test evidence. They report findings without editing. The
[agent tooling conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/agent-tooling.md)
cover the file layout, invocation in each tool and reviewer permissions.

## Screenshots

`AppTests/ScreenshotTests.swift` lists the app's screens and states, with fixed heading and
location input. CarPlay templates are not captured, though the dial thumbnail they show is
(`carplay-dial`). A pull request that adds or changes a screen adds or updates its entry there.
Add the `screenshots` label to capture the current PR head, using the largest and smallest
simulators in light and dark. While the label remains, each push or reopening requests another
capture; a push containing several commits captures only the resulting PR head. Adding unrelated
labels does not request a capture. Remove `screenshots` to stop future automatic captures.
Without it, the capture job is skipped on PR updates. Requested captures run independently, so
later pushes and label removal do not cancel an active capture. Each run checks out the head
commit recorded in its event and reports that exact commit in the run summary.

For custom captures, use Actions → Screenshots → Run workflow. Set `ref` to a branch, tag, commit
or pull request number (empty uses the run's branch), choose `devices` and `appearances`, and
narrow it with `filter` when only a few screens matter. Each run keeps its images for 7 days as a
`screenshots-run-<number>` artifact. Choose the `accessibility` set to capture the simulator part
of the App Store accessibility evidence
([#147](https://github.com/lunchbox-labs/compasslet/issues/147)) instead. It picks its own
simulators and appearances, applies text sizes and Bold Text in the test, and turns on Increase
Contrast and Reduce Transparency in the simulator, which the test confirms before capturing.
`ACCESSIBILITY_SET` in `scripts/screenshots` lists it. A named iPhone that iOS 27 supports but the
Mac hasn't set up is created for the run and deleted afterwards. A simulator with more than one
display, such as iPhone Duo, gets one image per display, ending in `-inner` for the largest and
`-outer` for the smallest. iPhone Duo boots folded and `simctl` can't open it, so the app shows
on the outer display and the inner images are black. Use these captures for mock-ups;
don't push other branches to produce them. Clients that can't download artifacts can set
`log-images` and read the images from the job log.
