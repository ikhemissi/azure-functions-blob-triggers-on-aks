# Findings — Azure Functions on AKS: three ways to trigger on a blob upload

**Date:** 2026-11-18 (phase 1) · **Versions tested:** [experiment 00](experiments/00-environment.md)

## Summary

Phase 1 (public endpoints, Entra authentication only) works for the three triggers with Workload Identity and no keys. Event Grid to Service Bus is the fastest path (median 1.6 s for 20 concurrent blobs), the polling Blob trigger follows (5.4 s), and Event Grid to a Storage queue is slowest with default settings (12.7 s, up to a minute after a quiet period, from the queue trigger's polling backoff; 1.5 to 2.7 s with `maxPollingInterval` at 2 s). With the idempotency record, every blob was processed exactly once through duplicates, killed pods, rolling restarts and a network outage. Phase 2 (private networking) is next; nothing here answers the private-networking part of Q1 yet.

## Answers

### Q1 — Which way of triggering Azure Functions on AKS after a blob upload works best with private networking, identity-only access and KEDA scaling, and at what latency, cost and operational effort?

Partly answered (phase 1): with public endpoints, Service Bus gives the lowest latency and kept up with 500 messages on one replica; the Storage queue needs its polling interval tuned to compete; the polling Blob trigger is simple but needs WebJobs blob extension 5.3.10 or later, and doesn't scale with KEDA ([02](experiments/02-phase-1-scenarios.md)). The private-networking and cost parts come with phase 2.

### Q2 — Workload Identity

Yes in phase 1: the host's own storage and the three triggers connect with `__credential=workloadidentity`, and KEDA's scalers with `podIdentity.provider: azure-workload` ([01](experiments/01-making-phase-1-run.md)).

### Q3 — Host IDs

Partly: replicas share their explicit host ID; restarts and a rolling update processed no blob twice ([02](experiments/02-phase-1-scenarios.md), scenarios 6 and 10). The host warns that an explicit host ID "is not a recommended configuration". Setting `POD_NAMESPACE` makes the host behave as on App Service on Kubernetes and broke the blob trigger's listener ([01](experiments/01-making-phase-1-run.md)). Behaviour without an explicit host ID: still to test.

### Q4 — The polling Blob trigger

Median 5.4 s (10 s container scan, then the trigger's internal queue). Receipts under `azure-webjobs-hosts/blobreceipts/<host ID>/…`, scan state under `blobscaninfo/<host ID>/<account>/<container>/scanInfo`, both in the host storage. Blobs uploaded while no pod ran were processed 3 s after the pods were ready. With WebJobs blob extension 5.3.8 and no Storage Analytics logs, new blobs weren't detected after the first scan; 5.3.10 fixes it, and the spike pins it ([01](experiments/01-making-phase-1-run.md)).

### Q5 — Event Grid to a Storage queue

Delivery works with the account's public access on, the system topic's identity holding its roles on the account ([01](experiments/01-making-phase-1-run.md)); messages are Base64-encoded. Selected networks and disabled access: phase 2.

### Q6 — Event Grid to Service Bus Premium

Phase 1 used Standard (public access on): delivery works. Premium with restricted access: phase 2.

### Q7 — KEDA

Both scalers work with Workload Identity; the queue app's scale-out was bounded by the two nodes' capacity (4 of 10 replicas), and the Service Bus app needed none for 500 messages ([02](experiments/02-phase-1-scenarios.md)). Scale to zero: still to test.

### Q8 — Least roles

Event Grid's check at subscription creation accepted its Storage roles (queue sender, dead-letter writer) only on the account, and the Service Bus sender role on the queue ([01](experiments/01-making-phase-1-run.md)). KEDA uses each app's own identity and roles. Narrower scopes: to test again in phase 2.

### Q9 — End-to-end latency

Phase 1, 20 concurrent blobs, median (p95): Service Bus 1.6 s (1.7), polling 5.4 s (5.9), Storage queue 12.7 s (13.6) ([02](experiments/02-phase-1-scenarios.md)). The Storage queue figure is the queue trigger's default polling backoff: with `extensions.queues.maxPollingInterval` at 2 s, its median was 1.5 to 2.7 s over three runs, at the price of polling an idle queue every 2 s ([03](experiments/03-queue-polling-interval.md)). Private endpoints: phase 2.

### Q10 — Probes

The anonymous `/admin/host/ping` keeps the pods ready; a pod scaled from zero was ready after 130 s. Behaviour while the host starts: still to measure.

### Q11 — Phase 2 operations

Phase 2.

### Q12 — At-least-once delivery

Exactly one processing record per blob through duplicate deliveries, a killed pod, a rolling restart and a 60 s outage; malformed events completed or dead-lettered with a reason; undecodable messages poisoned ([02](experiments/02-phase-1-scenarios.md)).

### Q13 — Cost

Phase 3.

## What we would do differently

- Pin the host's extension versions from the start and check them in the image (`.azurefunctions/function.deps.json`): the latest worker package didn't bring the fixed blob extension.
- Check that function logs reach Application Insights on the first deployment: with the host not running OpenTelemetry, the exporter's trace-based log sampling dropped every log written during an invocation.
- Size the node pool (or add the cluster autoscaler) for the scale-out you want to measure.
