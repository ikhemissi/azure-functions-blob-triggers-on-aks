# ADR-0003 — The Event Grid-based Blob trigger source is not used for the private AKS scenario

**Status:** Accepted (2026-11-19) · **Date:** 2026-11-18

## Context

The Blob trigger has two sources: the default polling one (`LogsAndContainerScan`) and an Event Grid one (`Source = BlobTriggerSource.EventGrid`), which has lower latency. With the Event Grid source, an Event Grid subscription of type **Web Hook** pushes each event to the Functions host's blob extension endpoint, `https://<app>/runtime/webhooks/blobs?functionName=…&code=<blobs_extension key>`.

In the private scenario (phase 2), the apps run in a private AKS cluster with no public ingress. Event Grid's push delivery can't deliver events to private endpoints: the receiving application can't receive them over private IP space.

## Decision

The spike does not use the Event Grid-based Blob trigger source. It compares the polling Blob trigger (app 1) and two event-driven paths in which Event Grid delivers to a broker the apps read from: a Storage queue (app 2) and a Service Bus queue (app 3).

## Consequences

- Good: no inbound path from the internet to the cluster; the apps only make outbound calls, to private endpoints in phase 2.
- Good: no webhook key (`blobs_extension`) to manage, rotate or keep out of the repository.
- Good: the broker buffers events while the apps are down or scaled to zero, and gives KEDA a queue length to scale on.
- Bad: one more hop (the broker) and one more resource to pay for and secure ([ADR-0004](ADR-0004-storage-queue-lower-cost-broker.md), [ADR-0005](ADR-0005-service-bus-premium-for-private-endpoints.md)).
- Bad: the apps read the blob themselves from the event's URL, and handle duplicates themselves ([ADR-0009](ADR-0009-at-least-once-and-idempotency.md)), instead of using the Blob trigger's binding and receipts.

## Alternatives considered

- **Event Grid Blob trigger source behind a public ingress:** the host's webhook endpoint exposed on the internet, protected by the extension key. Rejected: it contradicts the brief's private networking.
- **Event Grid trigger (`EventGridTrigger`)** with a webhook subscription: same inbound requirement. Rejected for the same reason.
- **Event Grid namespaces with pull delivery:** the consumer pulls over a private endpoint; see [ADR-0006](ADR-0006-no-event-grid-namespaces-pull-delivery.md).

## Evidence

Documented:

- The two Blob trigger sources and their latency: [Blob trigger — Choose a Blob storage trigger implementation](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-blob-trigger#choose-a-blob-storage-trigger-implementation); comparison (the event-driven Blob trigger doesn't work with inbound access restrictions): [Storage considerations — Trigger on a blob container](https://learn.microsoft.com/azure/azure-functions/storage-considerations#trigger-on-a-blob-container).
- The webhook endpoint, its extension key and the *Web Hook* endpoint type: [Tutorial: trigger on blob containers using an event subscription — Build the endpoint URL](https://learn.microsoft.com/azure/azure-functions/functions-event-grid-blob-trigger#build-the-endpoint-url).
- Push delivery can't deliver to private endpoints; pull delivery (namespaces) can be consumed over a private link: [Deliver events securely over a private link](https://learn.microsoft.com/azure/event-grid/consume-private-endpoints).

Observed:

- The polling Blob trigger's latency: one blob 2.6 to 20.6 s, median for 20 concurrent blobs 3.3 to 12.7 s over the runs of [02](../experiments/02-phase-1-scenarios.md), [03](../experiments/03-queue-polling-interval.md), [06](../experiments/06-phase-2-scenarios.md) and [07](../experiments/07-event-grid-destination-access.md), set by its 10 s container scan (Q4, Q9).
