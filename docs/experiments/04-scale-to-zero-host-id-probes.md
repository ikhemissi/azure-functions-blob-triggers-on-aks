# 04 — Scale to zero, no explicit host ID, probes at startup

**Date:** 2026-11-18 · **Answers:** Q3, Q7, Q10 · **Versions:** [00](00-environment.md)

## Goal

Three behaviours [02](02-phase-1-scenarios.md) left open on phase 1: KEDA scaling the event-driven apps to zero and back (Q7), the polling Blob trigger without an explicit host ID (Q3), and what `/admin/host/ping` answers while the host starts (Q10).

## Setup

Phase 1 as in 02. Each change was made on the live Deployments or ScaledObjects with `kubectl`, then reverted, so the cluster ends as the manifests describe:

- **Scale to zero:** `minReplicaCount: 0` on both ScaledObjects (KEDA defaults: 30 s polling, 300 s cooldown), then scenario 1 (one blob per app).
- **No host ID:** `AzureFunctionsWebHost__hostid` removed from blob-polling (2 replicas), with 3,236 blobs already in its uploads container, all processed before.
- **Probes:** on the rollout that restored the host ID, blob-polling's startup probe at every 1 s (timeout 1 s) instead of every 10 s (timeout 2 s), so that each failure shows up as a Kubernetes event.

## Results

### Scale to zero (Q7)

| Step | queue-triggered | servicebus-triggered |
|---|---|---|
| Scaled to zero after `minReplicaCount: 0` (queues already empty) | under 4 min | under 4 min |
| Blob uploaded → pod created | 14 s | 14 s |
| Pod created → Ready (image already on the node) | 10 s | 10 s |
| Upload → blob processed | 23.6 s | 23.1 s |
| Back to zero after the scale-up | 300 s | 300 s |

KEDA created the pods within its 30 s polling interval and removed them after its 300 s cooldown. One processing per blob, no retry.

### No explicit host ID (Q3)

Each pod took a host ID made of its own pod name: `blobpolling586d6b7f58jd2ht-21373` and `blobpolling586d6b7f58r9xx6-21373`. So the ID differs between the replicas and changes with every new pod.

| | Value |
|---|---|
| Blobs in the container before | 3,236 (3,236 records) |
| Processings in the 4.5 min after the rollout | 6,472, of which 6,471 logged `duplicate=true` |
| Records after | 3,237 (the one new blob of the scale-to-zero run) |

Each pod found no receipts under its new host ID and processed the whole container again: 3,236 blobs × 2 pods. The processing record caught every repeat. With the explicit, shared host ID restored, the receipts under `blob-polling` applied again.

### Probes at startup (Q10)

| Pod | Container started | "Host started" | Ready | Probe failures before Ready |
|---|---|---|---|---|
| 1 (quiet node) | 17:10:06 | 17:10:12.6 | 17:10:13 | 6 × connection refused |
| 2 (node at 96 % of its CPU requests) | 17:10:46 | 17:11:09.8 | 17:11:13 | 23 × connection refused, then 1 × timeout (1 s) |
| earlier pod (10 s period) | 16:54:27 | 16:54:33.5 | 16:54:38 | none recorded |

The host's HTTP port refuses connections until the host has started; the first successful ping came within about a second of "Host started" and "Job host started". In 02, pods scaled from zero by `kubectl scale` were Ready 130 s later, while the cluster was busy.

## Conclusion

- **Scale to zero (Q7):** works for the Storage queue and Service Bus scalers with Workload Identity. From zero, the first blob was processed about 23 s after its upload: up to 30 s of KEDA polling, then about 10 s to start a pod whose image is on the node. The apps returned to zero 5 minutes after the work. A cold node, an image pull or a full node adds to that.
- **Host ID (Q3):** without an explicit host ID, every pod has its own ID and every new pod processes the whole container again. Keep an explicit host ID that all replicas share and that doesn't change with the pods (as the manifests do), and keep the processing idempotent.
- **Probes (Q10):** `/admin/host/ping` is usable for the startup, readiness and liveness probes. It answers only after the host and its listeners have started, so Ready means the triggers run. The startup probe's budget (30 × 10 s) covers a slow start on a busy node.
