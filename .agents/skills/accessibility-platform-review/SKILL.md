---
name: accessibility-platform-review
description: Use when reviewing Compasslet accessibility, appearance, layout, location lifecycle, CarPlay, or Live Activity changes.
---

# Accessibility and platform review

Review the affected Compasslet platform states independently. Read the supplied diff, relevant surrounding code, and AGENTS.md. Do not edit files or change external state.

1. Identify the changed surfaces and supported versions from the current Xcode project and code. Inspect App/Heading and Shared for iPhone presentation, App/CarPlay for CarPlay templates, and App/LiveActivity plus CompassActivity for Live Activity lifecycle and presentation. Follow only relevant paths. Native Watch support is paused; do not require a Watch app runtime. Review automatic Live Activity mirroring only when the shared compact presentation is affected.
2. Check changed controls and readings for meaningful VoiceOver labels, values, traits, order, grouping, and announcements; match accessible control names to visible labels. Check Dynamic Type and custom text-size interactions, truncation, touch targets, contrast, color-independent meaning, light/dark appearance, and reduced-motion behavior where affected.
3. Check affected location authorization, unavailable/stale data, foreground/background transitions, and recovery. For CarPlay, inspect template constraints and glanceable presentation. For Live Activities, inspect start/update/end behavior, freshness, Lock Screen and Dynamic Island variants, and the small presentation used by CarPlay/mirroring. Check version availability and fallback behavior.
4. Use available screenshots, previews, test results, or simulator/device evidence. Identify device, OS, appearance, text size, and state when known. Separate source inference, static visual evidence, and runtime observations. An unexecuted test or preview is not observed behavior; screenshots do not establish VoiceOver behavior. Request missing evidence from the coordinating agent when your tools cannot obtain it.

Return only actionable findings, ordered by impact, with file/line or visual reference, affected platform/state, evidence type, user consequence, and the smallest correction. Finish with coverage and specific unverified states. A clean review is valid; do not invent findings or claim accessibility certification or device testing that did not occur.
