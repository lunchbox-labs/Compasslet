# Last travel reading in the Live Activity

Within one active drive, keep the last accepted true-north vehicle course when stopped, when the filter has no newer usable course, or when no new sample arrives. Show Last travel with original sample time. Do not renew its timestamp or mark retained data fresh. New samples still require existing five-second validity at acceptance and queued delivery. Unchanged displayed readings need no stale-date heartbeat. A changed reading remains limited to once a second.

Use no five-second ActivityKit stale date for this explicitly sampled display. Keep system stale state handling for legacy payloads/system lifecycle. Explicit sensor interruption clears the reading; permission/service loss, disconnect and existing eight-hour end clear/end it. Preserve #69 dismissal behavior. Never revive a prior-drive sample. Phone heading, regular widget and full-screen template policies stay unchanged.

Implement locally and independently review; no push or PR until approval. Device layout/delivery remains unverified.
