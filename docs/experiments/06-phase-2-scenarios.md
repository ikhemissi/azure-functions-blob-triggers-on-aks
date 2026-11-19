# 06 — Phase 2 scenarios

**Date:** 2026-11-18 · **Answers:** Q1, Q7, Q9, Q12 · **Versions:** [00](00-environment.md)

## Goal

Run the brief's scenarios again with private networking, and compare with phase 1 ([02](02-phase-1-scenarios.md)).

## Setup

Phase 2 after [05](05-making-phase-2-run.md): private endpoints for every storage account, Service Bus Premium and the registry, a private API server, `EVENT_GRID_DESTINATION_ACCESS=enabled`. The scenarios ran on the jumpbox, from 21:31 to 22:27 UTC, with the arguments of 02. Same apps and settings as in 02, images rebuilt from the same commit.

## Results

### Latency (scenarios 1 and 2)

| App | One blob (s) | 20 concurrent, median (s), three runs | p95 (s), three runs | Phase 1, median (p95) |
|---|---|---|---|---|
| blob-polling | 2.9 | 8.3 / 7.7 / 3.3 | 8.7 / 8.2 / 3.6 | 5.4 (5.9) |
| queue-triggered | 35.6 | 13.6 / 28.4 / 5.9 | 13.8 / 28.5 / 6.3 | 12.7 (13.6) |
| servicebus-triggered | 3.0 | 1.9 / 1.2 / 0.9 | 2.0 / 1.4 / 1.2 | 1.6 (1.7) |

The spread between runs comes from the triggers' polling (the blob scan every 10 s, the queue trigger's backoff up to 1 minute) rather than from the network: Service Bus, which pushes, stays between 0.9 and 1.9 s as in phase 1.

### Delivery and failures

| Scenario | blob-polling | queue-triggered | servicebus-triggered |
|---|---|---|---|
| 4: the same Event Grid event delivered twice | — | second processing logged as a duplicate, one record | second processing logged as a duplicate, one record |
| 5: one processing pod deleted mid-batch | 200 blobs, pod deleted at 82: 200/200, no retry or duplicate | 1,500 blobs, pod deleted at 1,099: 1,500/1,500, no retry or duplicate | 1,500 blobs, pod deleted at 882: 1,500/1,500, no retry or duplicate |
| 6: `kubectl rollout restart` into a batch of 1,000 | 20 s in, at 224: 1,000/1,000, no retry or duplicate | 20 s in, the batch was already done; run again 5 s in (2026-11-19, `trusted`), during the upload: 1,000/1,000, no retry or duplicate | the same; run again 5 s in, at 420: 1,000/1,000, no retry or duplicate |
| 7: egress blocked 60 s (NetworkPolicy), 10 blobs uploaded meanwhile | all processed 12 s after restore | 6 s after restore | 6 s after restore |
| 8: malformed and foreign events | — | malformed JSON and a blob URL in another account: completed and logged; a message that isn't Base64: moved to `blob-events-poison` | both dead-lettered with reason `MalformedEvent` |
| 9: blobs uploaded while the app ran no pods (60 s) | 20/20 processed 22 s after scaling back to 2 | — | — |
| 10: every Deployment restarted with the same host ID | 4,528 records before and after, none processed again | 8,163, none processed again | 8,469, none processed again |

No retry and no duplicate processing in any scenario.

### Scaling (scenario 3: 500 blobs per app)

| App | Replicas at the start | Peak | Queue drained (s) | Back to the minimum (s) | Records |
|---|---|---|---|---|---|
| queue-triggered | 4 | 4 | 33 | 276 | 500/500 |
| servicebus-triggered | 2 | 2 | 72 | 263 | 500/500 |

Both apps still had the replicas KEDA had added for scenario 2 (its cooldown is 300 s), so this run measures draining, not the scale-out from one replica; that is in 02.

## Conclusion

- **Private networking changes no behaviour (Q1, Q12):** every scenario of 02 gave the same result through private endpoints, with exactly one processing per blob through duplicates, killed pods, a rolling restart, an outage and malformed events.
- **Latency (Q9):** no measurable difference from phase 1. Service Bus stays the fastest (median 0.9 to 1.9 s for 20 blobs), then the polling trigger and the Storage queue, both bounded by their polling.
- **Scaling (Q7):** KEDA's scalers reach the Storage queue and Service Bus through their private endpoints with Workload Identity; the queue app drained 500 messages in 33 s on 4 replicas.
- **Scenario 6** needed a shorter `--restart-after` (5 s) for the event-driven apps: uploads from inside the virtual network are faster, and their batches finished within 20 s. Its progress count was fixed meanwhile (it counted the previous run's records too).
