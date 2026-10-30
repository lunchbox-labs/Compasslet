# Historical travel widget implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Preserve a bounded, clearly historical last reading across delayed widget delivery.
**Architecture:** Extend the shared snapshot validation with historical status and retention expiry, retain it only for missing fresh data during an eligible drive, and render age in every numeric layout. Add a separate bounded diagnostic table to the existing opt-in store.
**Tech Stack:** Swift, Foundation, SwiftUI/WidgetKit, SQLite, XCTest.
**Spec:** docs/superpowers/specs/2026-10-30-widget-history.md

## Global constraints
Five-second current freshness; 120-second history; 256 diagnostic events/30 wall-clock minutes; no new permissions, modes or signing. Do not change other surfaces or controls.

## Review focus
Delayed provider and render execution; stale-to-fresh transitions; stop/permission invalidation; old/malformed snapshots; disabled diagnostics and cross-process storage compatibility. Tests below exercise these classes; native paint timing remains untestable locally.

### Task 1: Snapshot and producer
- [x] Add failing snapshot tests for historical retention, delayed/repeated writes, expiry and compatibility. Add producer tests for initial reload, stale retention and invalidation.
- [x] Run snapshot XCTest harness and observe expected failures before implementation.
- [x] Implement historical validation/retention and timeline transition dates in Shared/LatestCourseSnapshot.swift; update DriveSessionController startup/publication preserving only missing-data history.
- [ ] Run snapshot tests and hosted controller tests (native CI), preserving five-second ActivityKit/fullscreen rules.

### Task 2: Diagnostics and widget
- [x] Add failing diagnostics tests for bounded metadata, opt-out/clear and failure outcomes.
- [x] Extend CompassDiagnostics with typed widget events; instrument producer lifecycle, app snapshot writes, provider invocation and reads.
- [x] Update CompassCourseWidget to preserve historical entry, schedule stale and unavailable transitions, and show Last recorded, age and stale state in every numeric layout/accessibility.
- [x] Run snapshot/diagnostics Linux harness, formatter, package release build/test and syntax checks. Native CI validates actual integration.

### Task 3: Review and publication
- [ ] Update usage docs, inspect changes and commit; open a draft PR linked to #48.
- [ ] Independent review; resolve findings and obtain latest-head re-review. Run native CI and mark ready only after review/checks pass. Report device gaps.

## Local verification record

Snapshot retention regressions failed before implementation. Historical interruption and early future-entry rendering regressions failed before correction. Swift 6.4.1 formatting/lint and release build pass; 20 portable core tests and 43 XCTest state tests pass in a Linux harness using actual snapshot/diagnostics/controller code (Combine observation stripped; sensor/ActivityKit protocols injected). Native build/rendering remains distinct. Reviewer corrections: historical status cannot become fresh without a new sample; avoid deprecated Text concatenation.
