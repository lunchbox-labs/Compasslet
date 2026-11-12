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

When the simulator tests fail in Check, the `native` job keeps their result bundle for 7 days as
the `check-test-results-run-<number>-attempt-<attempt>` artifact, with each failure's details,
the test timings and attachments. Passing runs keep nothing.

To check whether the simulator tests are flaky, use Actions → Repeat Tests → Run workflow on the
branch to test. It runs them up to `iterations` times (20 by default, 50 at most) and stops at the
first failure, keeping that failure's result bundle for 7 days. Each iteration relaunches the app,
so no in-memory state carries over between them. A run that's still going after 110 minutes stops
and keeps its bundle too. It runs only by hand, so it never blocks a merge. Locally,
`scripts/test-ios` passes its options to `xcodebuild`:

```sh
bash scripts/test-ios -test-iterations 20 -run-tests-until-failure -test-repetition-relaunch-enabled YES
```

Simulator tests inject heading and location input, so they don't validate the physical sensors
or in-car CarPlay operation. Physical-device checks are on the
[Development](wiki/Developer-Development.md#device-validation) wiki page.

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

## State machines

Much of the app's behavior lives in implicit state machines: flags, enums, optionals, tasks and
timers that together decide what a drive, the Live Activity, CarPlay or a permission prompt
does next. The
[State Machines](wiki/Developer-State-Machines.md) wiki page maps each one, its owner and its
known failure states.

Before changing code that keeps state across timers, tasks or app and scene lifecycles, find
the machine it belongs to on that page, or add it as a new machine with its own section and
Overview row. Update the page's states, transitions, diagrams and source references in the
same pull request as the change. Its file and line references are to one commit on `main`, and
readers search for the named symbol when lines have moved, so name code the change adds by
file and symbol without a line number. Re-pin the page to a newer `main` commit only when
refreshing every reference.

Test every transition the change adds or alters through observable behavior, not only the
expected path: failure and denial, relaunch and process termination, backgrounding and return,
and competing signals arriving in either order (for example, a permission change during a
start, or CarPlay disconnecting while a timer is pending). Report any transition you couldn't
exercise as a validation gap. For a new machine, or a change that would add another flag to an
existing one, prefer one explicit state value, such as an enum with associated data, over
separate booleans, so impossible combinations can't be represented.

When mapping or testing a machine turns up a reachable state the app doesn't handle and the
page doesn't list, such as a dead end, a resource that is never released or a state that
outlives its process, file a `bug` issue with how to reach it and the code that allows it.
Add it to the page's known failure states and to that machine's section. Fix it in the current
change only when that is the change's purpose; a change that fixes a listed failure state
marks it fixed on the page, with the pull request that fixed it, and removes it from that
machine's open failure states.

## Wiki

The [wiki](https://github.com/lunchbox-labs/compasslet/wiki) is published from the `wiki`
folder. Edit the pages there in a pull request, like any other change; the Wiki workflow
(`.github/workflows/wiki.yml`) makes the wiki match the folder when the change merges to
`main`, as a new commit on top of the wiki's history. Edits made on the wiki itself are
replaced by the next sync, so make them in the folder instead.

Each file name is a page name. Link between pages with the page name and no `.md`, as in
`[Publishing](Developer-Publishing)`, so links work on the wiki. `_Sidebar.md` is the wiki's
navigation; add a new page to it and to `Home.md`. `scripts/tests/test_wiki_links.py` checks
that `Home.md` exists and that every link to a wiki page names a page in the folder.

## Screenshots

`AppTests/ScreenshotTests.swift` lists the app's screens and states, with fixed heading and
location input. CarPlay templates are not captured, though the dial thumbnail they show is
(`carplay-dial`). A pull request that adds or changes a screen adds or updates its entry there.
Add the `screenshots` label to capture the current PR head, using the largest and smallest
simulators in light and dark. While the label remains, each push or reopening requests another
capture; a push containing several commits captures only the resulting PR head. Adding unrelated
labels does not request a capture. Remove `screenshots` to stop future automatic captures.
Without it, the capture job is skipped on PR updates. A newer capture request for a PR cancels
its capture still in progress, since only the newest head needs screenshots; removing the label or
adding an unrelated one does not cancel it. Manual runs never cancel each other or PR captures.
Each run checks out the head commit recorded in its event and reports that exact commit in the
run summary.

For custom captures, use Actions → Screenshots → Run workflow. Set `ref` to a branch, tag, commit
or pull request number (empty uses the run's branch), choose `devices` and `appearances`, and
narrow it with `filter` when only a few screens matter. Each run keeps its images for 7 days as a
`screenshots-run-<number>` artifact, with `-attempt-<n>` added for a re-run.

A screen whose content runs past the display, as many do at the accessibility text sizes, is
captured in parts. After the usual capture, the test scrolls the screen's largest scroll view
that has more below, about one visible height at a time with a little of the previous part kept,
and captures each further part until the end is on screen. The first part keeps the screen's
name; later parts add `-part2`, `-part3` and so on. In `screenshots.json`, every image of a
screen captured in parts has a `part` number, and images of other screens have none. Screens
that fit are captured exactly as before. The `max-parts` input (`--max-parts` in the script;
from 1, only the top, to 9, the default) caps the captures per screen. Screens shown at a
chosen scroll position, with a tip or the share sheet over them, or with the location prompt up,
are captured only as shown. Set `scrollsInParts: false` on a `Screen` entry to leave out
another, as `compass-settings-sheet` does.

Choose the `accessibility` set instead of every screen to capture the simulator part of the App
Store accessibility evidence ([#147](https://github.com/lunchbox-labs/compasslet/issues/147)). It
picks its own simulators and appearances, applies text sizes and Bold Text in the test, and turns
on Increase Contrast and Reduce Transparency in the simulator, which the test confirms before
capturing. `ACCESSIBILITY_SET` in `scripts/screenshots` lists it. A named iPhone that iOS 27
supports but the Mac hasn't set up is created for the run and deleted afterwards. Use these
captures for mock-ups; don't push other branches to produce them. Clients that can't download
artifacts can set `log-images` and read the images from the job log.

Choose the `listing` set for the App Store listing screenshots: the `compass` screen in light and
dark on iPhone 17. Publish captures this set at the commit it uploads and replaces the version's
listing screenshots with it; Release captures every screen at the released commit for its GitHub
Release. Both call this workflow, so its inputs and the `artifact` output must stay in step.
Apple's screenshot specifications list one required iPhone size, iPhone with Dynamic Island
(medium display), which iPhone 17 is. `LISTING_SET` in `scripts/screenshots` lists
it. The app is iPhone only, so the listing has no iPad screenshots
([#309](https://github.com/lunchbox-labs/compasslet/issues/309)). Apple Watch
([#304](https://github.com/lunchbox-labs/compasslet/issues/304)) and iPhone Duo
([#305](https://github.com/lunchbox-labs/compasslet/issues/305)) are left out of the first release;
Apple says iPhone Duo screenshots become required from April 2027 for apps built with the iOS 27.1
SDK or later.
