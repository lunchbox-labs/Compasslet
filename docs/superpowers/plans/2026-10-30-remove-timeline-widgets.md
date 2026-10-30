# Remove timeline widgets implementation plan

**Spec:** `docs/superpowers/specs/2026-10-30-remove-timeline-widgets.md`

Goal: Remove every ordinary timeline widget while retaining the ActivityKit extension, native CarPlay template and phone compass.

1. Delete timeline widget and latest-course storage/provider code and Xcode source references. Keep extension identity, ActivityConfiguration, App Group and signing unchanged. Remove the retired snapshot directory on app initialization.
2. Remove snapshot/reload/diagnostic callbacks from drive lifecycle; preserve acquisition, permission checks, five-second full-screen filtering and all ActivityKit sequencing.
3. Remove widget appearance surface while decoding old preferences without losing phone/activity overrides. Remove widget diagnostic stream and migrate old databases without breaking retained timing exports.
4. Replace widget-only tests with migration coverage; retain and run activity/drive/CarPlay/phone suites. Update current README and mark prior widget design docs historical.
5. Check no timeline registration/reload API remains, inspect project wiring and entitlements, independent review, draft PR and native CI. No merge.
