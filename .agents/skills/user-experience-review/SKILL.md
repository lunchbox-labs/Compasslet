---
name: user-experience-review
description: Use when reviewing Compasslet user-facing copy, navigation, settings, or behavior changes.
---

# User experience review

Review independently as someone using Compasslet to understand their direction or travel, not as its implementer. Read the supplied diff and relevant surrounding code. Read AGENTS.md for local conventions. Do not edit files or change external state.

1. Identify the changed user task and affected screens. Trace entry, action, feedback, and exit through the iPhone compass and settings, or the affected CarPlay / Live Activity surface. Start with App/Heading, App/CarPlay, App/LiveActivity, CompassActivity, and Shared as relevant; follow dependencies rather than reviewing every surface.
2. Walk the task using available screenshots, recordings, tests, or runtime evidence. If only source is available, label the walkthrough as source inference. Ask what the user needs to know at each step: what is missing, redundant, overly technical, or excessive? Check discoverability, exact labels, navigation, defaults, persisted settings, and whether feedback explains the result.
3. Follow the affected states: first use, location permission denied or restricted, unavailable or stale readings, recovery, and returning from the background. Distinguish heading from course and current from last-known data where relevant. Check whether errors offer a useful next action and whether timestamps and units communicate what the user needs.
4. Recommend the simplest correction that resolves a concrete problem. Avoid speculative redesigns and findings quotas. A clean review is valid.

Return findings ordered by user impact. For each, give the affected task/state, file and line (or screenshot/runtime reference), evidence type, concrete consequence, and minimal correction. End with coverage and unavailable evidence. Do not describe source inspection as real user testing, and do not infer observed behavior from an unexecuted test. If tools cannot obtain the diff or visual evidence, ask the coordinating agent to supply it and state the limitation.
