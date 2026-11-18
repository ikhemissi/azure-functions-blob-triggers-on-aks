# 02 — Phase 1 scenarios

**Date:** 2026-11-18 · **Answers:** Q3, Q4, Q5, Q7, Q9, Q10, Q12 · **Versions:** [00](00-environment.md)

## Goal

Run the brief's test scenarios (`scripts/scenarios/`) against phase 1 (public endpoints, Entra only) and record latency, scaling and delivery behaviour per trigger.

## Setup

Phase 1 after the changes of [01](01-making-phase-1-run.md): blob-polling with 2 fixed replicas; queue-triggered and servicebus-triggered with KEDA (min 1, max 10, 5 messages per replica); host.json defaults except the blob extension's `maxDegreeOfParallelism` 8 and the queue trigger's `maxDequeueCount` 5. Latency is the processing end minus the blob's creation time, from each app's `Blob processing finished` record in Application Insights.

## Results

### Latency (scenarios 1 and 2)

| App | One blob (s) | 20 concurrent: min / median / p95 / max (s) |
|---|---|---|
| blob-polling | 5.7 | 5.1 / 5.4 / 5.9 / 5.9 |
| queue-triggered | 39.5 | 12.6 / 12.7 / 13.6 / 13.7 |
| servicebus-triggered | 1.7 | 0.7 / 1.6 / 1.7 / 1.7 |

The Storage queue path waits for the queue trigger's polling: when the queue is empty, the trigger backs off up to `extensions.queues.maxPollingInterval` (1 minute by default), so a first message after a quiet period can wait up to a minute. The blob container scan runs every 10 s (not configurable), then the blob passes through the trigger's internal queue.

### Delivery and failures

| Scenario | blob-polling | queue-triggered | servicebus-triggered |
|---|---|---|---|
| 4: the same Event Grid event delivered twice | — | second processing logged as a duplicate, one record | second processing logged as a duplicate, one record |
| 7: egress blocked 60 s (NetworkPolicy), 10 blobs uploaded meanwhile | all processed 10 s after restore; 1 retry, its duplicate caught by the record | all processed 18 s after restore | all processed 11 s after restore |
| 8: malformed and foreign events | — | malformed JSON and a blob URL in another account: completed and logged; a message that isn't Base64: moved to `blob-events-poison` | both dead-lettered with reason `MalformedEvent` |
| 5: one processing pod deleted mid-batch | 200 blobs, pod deleted at 164: 200/200, no retry or duplicate | 1,500 blobs, pod deleted at 396: 1,500/1,500, no retry or duplicate | 1,500 blobs, pod deleted at 544: 1,500/1,500, no retry or duplicate |
| 6: `kubectl rollout restart` mid-batch (1,000 blobs) | restarted at 488: 1,000/1,000, no retry or duplicate | restarted at 606: 1,000/1,000 | restarted at 471: 1,000/1,000 |
| 9: blobs uploaded while the app ran no pods (60 s) | 20/20 processed 3 s after the pods were ready; pods ready 130 s after scaling back to 2 | — | — |
| 10: every Deployment restarted with the same host ID | 354 existing blobs, none processed again | none processed again | none processed again |

Event Grid's messages in the Storage queue are Base64-encoded: the queue trigger reads them with `messageEncoding: base64` (Q5).

### Scaling (scenario 3: 500 blobs per app)

| App | Peak replicas | Time to peak (s) | Queue drained (s) | Back to the minimum (s) | Records |
|---|---|---|---|---|---|
| queue-triggered | 4 (KEDA asked for 10) | 148 | 39 | 334 | 500/500 |
| servicebus-triggered | 1 | — | 81 | — | 500/500 |

KEDA scaled the queue app's HorizontalPodAutoscaler to 10 within 40 s, but only 4 pods fit: the others stayed Pending ("0/2 nodes are available: 1 Insufficient cpu, 1 Insufficient memory") on the two 2-vCPU nodes, with requests of 100m CPU and 256 MiB per pod beside the system pods. The Service Bus app processed the 500 messages on its single replica faster than KEDA's metric showed a backlog, so it never scaled. The cluster has no node autoscaler: capacity, not KEDA, bounded the scale-out here.

## Conclusion

- **Latency (Q9):** Service Bus is the fastest (median 1.6 s for 20 concurrent blobs), then the polling Blob trigger (5.4 s, from the 10 s scan), then the Storage queue (12.7 s, from the queue trigger's polling backoff, up to a minute after a quiet period). The Storage queue figure is a default setting, not a limit: a tuning run with a lower `maxPollingInterval` comes next.
- **Delivery (Q12):** across duplicate deliveries, a pod killed mid-batch, a rolling restart mid-batch and a 60 s outage, every blob ended with exactly one processing record; the one retry seen (polling trigger, after the outage) was caught as a duplicate by the record. Malformed events are completed (Storage queue) or dead-lettered with a reason (Service Bus); a message the trigger can't decode goes to the poison queue.
- **Host IDs (Q3):** with an explicit host ID, restarts and rollouts processed no blob twice, and the polling trigger's receipts kept 354 existing blobs from running again.
- **Existing blobs (Q4):** blobs uploaded while the polling app ran no pods were processed 3 s after its pods were ready.
- **Scaling (Q7):** KEDA's Storage queue and Service Bus scalers work with Workload Identity; scale-out was bounded by the cluster's capacity. Scale to zero, a node autoscaler and the time to start a pod (130 s from scale-up to ready in scenario 9) are still to measure.
- Not shown here: anything about private networking (phase 2).
