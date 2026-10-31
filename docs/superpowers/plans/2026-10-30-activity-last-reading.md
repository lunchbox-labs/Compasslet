# Live Activity retention implementation plan

Goal: retain one honestly labeled sample during stops without broadening acquisition.
Spec: ../specs/2026-10-30-activity-last-reading.md

- Add failing activity tests for slow/unreliable/missing samples, appearance after age, unchanged-course coalescing, delayed queue acceptance, explicit interruption and next-drive clearing.
- Change only activity retention/gating and nil stale-date payloads; keep fresh input admission, sample timestamps and serialized invalidation.
- Add a distinct activity invalidateReading path for sensor interruption, preserving pending invalidations across coalesced updates.
- Add Last travel/sample time to activity presentation without changing widget/full-screen behavior.
- Run portable suite and local state harness; format/lint and syntax check. Obtain independent review and return local candidate with native/device/publication gaps.

## Local result

Completed locally against main 187ab43. Five-second admission remains; no five-second stale date is attached to accepted last-reading ActivityKit payloads. Low speed, absent course and expired queued samples retain prior accepted content without new timestamp. Explicit interruption uses a separate clear path, with pending clear ordering protected during startup and repeated interruptions.

Swift 6.4.1 release build, format/lint, syntax parsing and 22 portable tests pass. A Linux harness using the actual state code (with ActivityKit/Combine observation and appearance-store integration stubbed) passes 46 XCTest state tests and 14 activity tests. Independent review reproduced and verified fixes for expired drive-queued input, startup interruption recovery, repeated interruption ordering and visible historical semantics on compact/minimal Dynamic Island. Final independent review: no remaining actionable findings; all three independent state reproductions pass.

Native compilation and actual ActivityKit/CarPlay rendering remain unverified: no Xcode/xcrun is available locally. No push or PR is authorized yet. Issue #73 tracks this separate Live Activity change; regular widget/full-screen/phone policies are untouched.
