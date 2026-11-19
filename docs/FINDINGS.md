# Findings — Azure Functions on AKS: three ways to trigger on a blob upload

**Date:** 2026-11-18 (phase 1), 2026-11-19 (phase 2) · **Versions tested:** [experiment 00](experiments/00-environment.md)

## Summary

Phase 1 (public endpoints, Entra authentication only) works for the three triggers with Workload Identity and no keys. Event Grid to Service Bus is the fastest path (median 1.6 s for 20 concurrent blobs), the polling Blob trigger follows (5.4 s), and Event Grid to a Storage queue is slowest with default settings (12.7 s, up to a minute after a quiet period, from the queue trigger's polling backoff; 1.5 to 2.7 s with `maxPollingInterval` at 2 s). With the idempotency record, every blob was processed exactly once through duplicates, killed pods, rolling restarts and a network outage. Phase 2 (private endpoints everywhere, private API server and registry) changed none of these results ([06](experiments/06-phase-2-scenarios.md)), and Event Grid kept delivering with public access off on its destinations ([07](experiments/07-event-grid-destination-access.md)); operations move to a jumpbox, where the images are also built ([05](experiments/05-making-phase-2-run.md)). Cost decides between the event-driven options with private networking: Service Bus Premium is about €608 a month, the Storage queue's own cost a few euros ([08](experiments/08-costs.md)). Answer to Q1: Event Grid to a Storage queue with a lowered polling interval.

## Answers

### Q1 — Which way of triggering Azure Functions on AKS after a blob upload works best with private networking, identity-only access and KEDA scaling, and at what latency, cost and operational effort?

**Event Grid to a Storage queue, with the queue trigger's `maxPollingInterval` lowered (2 s here),** for private networking with identity only and KEDA:

- **Latency:** median 1.5 to 2.7 s for 20 concurrent blobs, against 0.9 to 1.9 s for Service Bus and 3 to 13 s for the polling trigger, over the runs of [03](experiments/03-queue-polling-interval.md), [06](experiments/06-phase-2-scenarios.md) and [07](experiments/07-event-grid-destination-access.md). With the default backoff it is the slowest (13 s, up to a minute after a quiet period).
- **Cost:** about €2 a month of its own at a million blobs; Service Bus needs Premium for private endpoints, about €608 a month ([08](experiments/08-costs.md)).
- **Private networking and identity:** Event Grid delivers into the account with its public access off; the app, KEDA and Event Grid use managed identities only ([07](experiments/07-event-grid-destination-access.md)).
- **Scaling:** KEDA's queue scaler, to zero and back in about 23 s ([04](experiments/04-scale-to-zero-host-id-probes.md)).

**Service Bus** when its features matter more than about €600 a month (dead-lettering with a reason, sessions, duplicate detection) or its push latency does; it behaved the same in every scenario. **The polling Blob trigger** needs no Event Grid and costs little, but it doesn't scale with KEDA, its latency follows a 10 s container scan, it needs WebJobs blob extension 5.3.10 or later, and every new pod without a shared host ID processes the whole container again ([01](experiments/01-making-phase-1-run.md), [04](experiments/04-scale-to-zero-host-id-probes.md)).

Operational effort is the same for the three in phase 2: deployments and tests run from a jumpbox in the network, and images are built there ([05](experiments/05-making-phase-2-run.md)). Every option processed each blob exactly once with the idempotency record (Q12).

### Q2 — Workload Identity

Yes in phase 1: the host's own storage and the three triggers connect with `__credential=workloadidentity`, and KEDA's scalers with `podIdentity.provider: azure-workload` ([01](experiments/01-making-phase-1-run.md)).

### Q3 — Host IDs

Partly: replicas share their explicit host ID; restarts and a rolling update processed no blob twice ([02](experiments/02-phase-1-scenarios.md), scenarios 6 and 10). The host warns that an explicit host ID "is not a recommended configuration". Setting `POD_NAMESPACE` makes the host behave as on App Service on Kubernetes and broke the blob trigger's listener ([01](experiments/01-making-phase-1-run.md)). Without an explicit host ID, each pod takes one made of its pod name, so every new pod found no receipts and processed the whole container again (3,236 blobs × 2 pods, all caught by the processing record) ([04](experiments/04-scale-to-zero-host-id-probes.md)): keep an explicit host ID shared by the replicas.

### Q4 — The polling Blob trigger

Median 5.4 s (10 s container scan, then the trigger's internal queue). Receipts under `azure-webjobs-hosts/blobreceipts/<host ID>/…`, scan state under `blobscaninfo/<host ID>/<account>/<container>/scanInfo`, both in the host storage. Blobs uploaded while no pod ran were processed 3 s after the pods were ready. With WebJobs blob extension 5.3.8 and no Storage Analytics logs, new blobs weren't detected after the first scan; 5.3.10 fixes it, and the spike pins it ([01](experiments/01-making-phase-1-run.md)).

### Q5 — Event Grid to a Storage queue

Delivery works with the account's public access on, the system topic's identity holding its roles on the account ([01](experiments/01-making-phase-1-run.md)); messages are Base64-encoded. With the account limited to no networks (default action Deny, trusted services and a resource instance rule) and with its public access off, Event Grid still delivered, while clients outside the virtual network were refused ([07](experiments/07-event-grid-destination-access.md)).

### Q6 — Event Grid to Service Bus Premium

Delivery works with public access on (Standard in phase 1, Premium in phase 2) and off, with the trusted-services bypass. The namespace refuses the in-between shape, default action Deny with no IP or network rules while public access is on (`InvalidNetworkRuleSetUpdate`), so "limited with trusted services" means public access off for Service Bus ([07](experiments/07-event-grid-destination-access.md)).

### Q7 — KEDA

Both scalers work with Workload Identity; the queue app's scale-out was bounded by the two nodes' capacity (4 of 10 replicas), and the Service Bus app needed none for 500 messages ([02](experiments/02-phase-1-scenarios.md)). From zero, a blob was processed 23 s after its upload (KEDA's 30 s polling, then 10 s to start a pod with a cached image), and the apps returned to zero 5 minutes after the work ([04](experiments/04-scale-to-zero-host-id-probes.md)). Private endpoints: phase 2.

### Q8 — Least roles

Event Grid's check at subscription creation accepted its Storage roles (queue sender, dead-letter writer) only on the account, and the Service Bus sender role on the queue ([01](experiments/01-making-phase-1-run.md)). KEDA uses each app's own identity and roles. Narrower scopes: to test again in phase 2.

### Q9 — End-to-end latency

Phase 1, 20 concurrent blobs, median (p95): Service Bus 1.6 s (1.7), polling 5.4 s (5.9), Storage queue 12.7 s (13.6) ([02](experiments/02-phase-1-scenarios.md)). The Storage queue figure is the queue trigger's default polling backoff: with `extensions.queues.maxPollingInterval` at 2 s, its median was 1.5 to 2.7 s over three runs, at the price of polling an idle queue every 2 s ([03](experiments/03-queue-polling-interval.md)). Private endpoints: no measurable difference ([06](experiments/06-phase-2-scenarios.md)).

### Q10 — Probes

The anonymous `/admin/host/ping` keeps the pods ready; a pod scaled from zero was ready after 130 s on a busy cluster ([02](experiments/02-phase-1-scenarios.md)). While the host starts, its port refuses connections; the first successful ping came within about a second of "Host started", so Ready means the listeners run ([04](experiments/04-scale-to-zero-host-id-probes.md)).

### Q11 — Phase 2 operations

Deploying and testing run on the jumpbox, reached through an on-demand Bastion session. azd's remote build (an ACR Tasks quick run) is refused by the registry once its public access is off, Tasks bypass or not; building with Docker on the jumpbox and pushing through the private endpoint works (73 to 110 s per app). The jumpbox needs the .NET SDK, make and Docker besides the CLI tools, and one sign-in ([05](experiments/05-making-phase-2-run.md)).

### Q12 — At-least-once delivery

Exactly one processing record per blob through duplicate deliveries, a killed pod, a rolling restart and a 60 s outage; malformed events completed or dead-lettered with a reason; undecodable messages poisoned ([02](experiments/02-phase-1-scenarios.md)). The same through private endpoints ([06](experiments/06-phase-2-scenarios.md)).

### Q13 — Cost

Each trigger's own cost per month at a million blobs, list prices ([08](experiments/08-costs.md)): Storage queue €1.58 (€2.04 polled every 2 s), polling trigger €7.77, Service Bus Standard €9.46 with public endpoints; with private endpoints, Service Bus needs Premium, €608 for one messaging unit. Shared by every option in phase 2: private endpoints (about €33 a month per app), the registry Premium (€41 more than Basic) and a Bastion session (€0.39 a working hour). The spike's environment: €0.19 an hour in phase 1, €1.22 in phase 2.

## What we would do differently

- Pin the host's extension versions from the start and check them in the image (`.azurefunctions/function.deps.json`): the latest worker package didn't bring the fixed blob extension.
- Check that function logs reach Application Insights on the first deployment: with the host not running OpenTelemetry, the exporter's trace-based log sampling dropped every log written during an invocation.
- Size the node pool (or add the cluster autoscaler) for the scale-out you want to measure.
