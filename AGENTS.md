# Agent instructions

Before working in this repository, read and follow these shared Lunchbox Labs documents:

- [Common agent guidance](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/common.md)
- [Workflow conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/workflows.md)
- [iOS app conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/ios-apps.md)
- [Agent tooling conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/agent-tooling.md)

Read these documents explicitly; GitHub does not automatically inherit them into this repository.

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
location input; CarPlay itself is not captured. A pull request that adds or changes a screen
adds or updates its entry there, and the Screenshots workflow then captures it on that pull
request. For a change that doesn't touch the list, run the workflow by hand with `ref` set to
the branch or pull request number, and narrow it with `filter` when only a few screens matter.
Use these captures for mock-ups; don't push other branches to produce them. Clients that can't
download artifacts can set `log-images` and read the images from the job log.

Every merge to `main` keeps one current set as the `screenshots-main` artifact.

## Releases

Pushing a version tag such as `v1.2.0` runs Publish, which uploads that build to TestFlight,
ready to submit for App Store review. Once Apple approves it, run the Release workflow with the tag. It captures
every screen at the tag, publishes the tag's GitHub Release with the images and generated
notes, and points the Release Screenshots wiki page at the latest release. Releases are
immutable, so the workflow attaches everything to a draft before publishing it.
