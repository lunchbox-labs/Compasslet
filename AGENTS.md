# Agent instructions

Before working in this repository, read and follow these shared Lunchbox Labs documents:

- [Common agent guidance](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/common.md)
- [Workflow conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/workflows.md)
- [iOS app conventions](https://github.com/lunchbox-labs/.github/blob/main/agent-guidance/ios-apps.md)

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

## Focused independent reviews

For user-facing copy, navigation, settings, or behavior changes, delegate an
independent pass to `user-experience-reviewer` using
[the user experience procedure](.agents/skills/user-experience-review/SKILL.md).
For changes to accessibility, appearance/layout, location lifecycle, CarPlay, or
Live Activities, also use `accessibility-platform-reviewer` with
[the platform procedure](.agents/skills/accessibility-platform-review/SKILL.md).
Use only the applicable roles; contributor tooling or unrelated internal changes
do not need these product reviews.

Give reviewers the diff/base, intended user task, and available screenshots or
runtime/test evidence. They report findings without editing. Address findings and
have the independent reviewer recheck fixes before declaring readiness. If the
runtime cannot spawn a reviewer, report that gap; a self-review is not independent.

The procedures above are canonical. Codex and OpenCode discover `.agents/skills`;
Claude's `.claude/skills` files forward to them. Named agents live in each tool's
native agents directory. Ask Codex or Claude to use the named reviewer; in OpenCode
mention `@user-experience-reviewer` or `@accessibility-platform-reviewer`.
For a direct procedure run, use `$user-experience-review` in Codex,
`/user-experience-review` in Claude, or the `user-experience-review` skill in
OpenCode (and likewise for `accessibility-platform-review`). Direct runs in the
implementer's context do not replace an independent review.
Codex reviewers inherit parent permissions; their non-editing boundary is an
instruction. Claude and OpenCode adapters limit tools to reading and searching;
provide diff and runtime artifacts they cannot collect themselves.
