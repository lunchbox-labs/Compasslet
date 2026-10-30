> Historical: the ordinary timeline widget described here was removed. The ActivityKit Live Activity remains supported.

# Historical travel widget

Keep one last recorded vehicle-course sample for at most 120 seconds. Freshness remains five seconds; after that the sample is explicitly stale. Every numeric rendering says Last recorded and includes its sample age/time, even if WidgetKit delays a state transition. The widget never acquires location and no permissions or capabilities change. Stop, denied/revoked permissions, service loss and invalid measurements clear the shared bearing; lack of new data may retain a historical sample within its age limit. Cached system renders may lag invalidation; do not claim immediate screen removal.

Use the existing shared snapshot, adding a historical state and separate retention expiry. Keep actual sample timestamps across reads/writes and a future unavailable timeline entry at the retention deadline. Request the initial waiting reload. Add opt-in, fixed-enum diagnostic events for acquisition lifecycle/reasons, snapshot I/O and provider invocation/sample age. Bound those records to 256 events and 30 wall-clock minutes; no bearings, coordinates, error strings or history of readings.

This fixes a reproduced producer/timeline mismatch; it does not establish the precise cause of the reported device failure. Preserve other surfaces and current drive lifecycle. Independent review and native CI are required before ready-for-review; physical display timing remains a device check.
