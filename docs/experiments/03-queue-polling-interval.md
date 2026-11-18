# 03 — Storage queue polling interval

**Date:** 2026-11-18 · **Answers:** Q9 · **Versions:** [00](00-environment.md)

## Goal

In [02](02-phase-1-scenarios.md), the Storage queue path was the slowest (median 12.7 s for 20 concurrent blobs, 39.5 s for one blob after a quiet period). Check how much of that comes from the queue trigger's polling backoff, which `extensions.queues.maxPollingInterval` (1 minute by default) bounds.

## Setup

Phase 1 as in 02, with one change to the queue-triggered Deployment only: the environment variable `AzureFunctionsJobHost__extensions__queues__maxPollingInterval=00:00:02` (the host.json setting through configuration), set with `kubectl set env`. The host logged `"MaxPollingInterval": "00:00:02"` in its queue options at startup. The other two apps were unchanged and serve as the reference. Scenario 1 ran once and scenario 2 three times, 90 s apart. The setting was then removed, so later experiments run with the defaults as in 02.

## Results

| App | One blob (s) | 20 concurrent, median (s), three runs | p95 (s), three runs |
|---|---|---|---|
| blob-polling | 12.4 | 4.7 / 7.5 / 8.8 | 5.2 / 8.0 / 9.3 |
| queue-triggered (2 s) | 3.6 | 1.5 / 2.2 / 2.7 | 1.7 / 2.4 / 3.9 |
| servicebus-triggered | 2.4 | 1.1 / 1.8 / 1.8 | 1.2 / 2.0 / 1.8 |

Every run: 20/20 records, no retry, no duplicate. With the default interval (02): queue-triggered 39.5 s for one blob, median 12.7 s for 20.

The polling Blob trigger's figures vary from run to run with where the upload falls in its 10 s scan cycle (one blob: 5.7 s in 02, 12.4 s here).

## Conclusion

- **Latency (Q9):** with `maxPollingInterval` at 2 s, Event Grid to a Storage queue has a median of 1.5 to 2.7 s for 20 concurrent blobs, close to Service Bus (1.1 to 1.8 s) and faster than the polling Blob trigger (4.7 to 8.8 s). The 12.7 s in 02 came from the default backoff, not from the path itself.
- **The trade-off:** an idle queue is polled every 2 s instead of backing off to every minute, which is about 43,200 queue requests a day per replica instead of about 1,440. The cost of those requests goes into the comparison of phase 3 (Q13).
- The project keeps the default in `host.json`; a lower interval is a setting to choose per workload.
