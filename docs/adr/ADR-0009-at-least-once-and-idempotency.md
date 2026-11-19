# ADR-0009 — At-least-once delivery and idempotency

**Status:** Accepted (2026-11-19) · **Date:** 2026-11-18

## Context

Every path delivers a blob to the app **at least once**: Event Grid retries and may deliver duplicates; a Storage queue message reappears when its function fails; a Service Bus message is delivered again when its lock expires before it is settled. A pod restart during processing, a rolling deployment or a dependency briefly unavailable all lead to a second delivery. Blob events can also arrive late or out of order, after the blob has changed. The polling Blob trigger keeps receipts, but they live under the host ID and host storage ([ADR-0002](ADR-0002-replicas-share-one-host-id.md)).

## Decision

The three apps share one processing step (`src/BlobProcessing`, see [DESIGN.md — Processing](../DESIGN.md#processing-the-same-in-the-three-apps)):

1. **Idempotency key:** `<account>/uploads/<blob name>/<version ID or ETag>/process`; one blob version is one unit of work.
2. **Record after the work:** once the blob is read, insert one entity in the `processed` table of the app's host account (partition key: the app; row key: SHA-256 hex of the key). `409 Conflict` means already processed: logged with `duplicate=true`. A crash before the insert means a retry, never a lost blob.
3. **Superseded events** (apps 2 and 3): if the event's ETag no longer matches the blob's, or the read returns `412`, the event is logged as superseded and completed without a record; the newer version has its own event.
4. **Poison and dead-letter:** malformed events are not retried (app 2 completes them, app 3 dead-letters them with reason `MalformedEvent`). Failures are retried by the trigger, then set aside: `webjobs-blobtrigger-poison` (app 1), `blob-events-poison` after 5 dequeues (app 2), the Service Bus dead-letter queue after 5 deliveries (app 3). Event Grid dead-letters what it can't deliver to `eventgrid-deadletter`.

## Consequences

- Good: exactly one *recorded* processing per blob version, whatever the trigger, with one log field (`duplicate`) to count duplicates.
- Good: no lost blob: recording last turns every failure into a retry.
- Bad: the work itself may run more than once (two concurrent deliveries both do it; one records). Real work must be idempotent too, or write its result in the same step as the record.
- Bad: one table write per blob, in the host account; the record has no expiry.
- Bad: a blob deleted before its event is processed fails the read (`404`), is retried, then ends in poison or dead-letter in the current code (Q12).
- Bad: four places to watch for set-aside items (two poison queues, a dead-letter queue, a dead-letter container).

## Alternatives considered

- **Record before the work:** at-most-once: a crash after the record loses the blob. Rejected.
- **Service Bus duplicate detection:** Service Bus only, configured on the sender's side (here Event Grid); the other two paths are not covered. Not used.
- **Rely on the Blob trigger's receipts:** app 1 only, and tied to the host ID and host storage. Kept as is, not relied on.

## Evidence

Documented:

- Event Grid delivers at least once, retries, may duplicate, dead-letters: [Event Grid message delivery and retry](https://learn.microsoft.com/azure/event-grid/delivery-and-retry#dead-letter-events).
- Late and out-of-order Blob events; use the ETag and the sequencer: [Reacting to Blob storage events — Practices for consuming events](https://learn.microsoft.com/azure/storage/blobs/storage-blob-event-overview#practices-for-consuming-events).
- Queue trigger poison queue: [Poison messages](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-queue-trigger#poison-messages); poison blobs: [Poison blobs](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-blob-trigger#poison-blobs); Service Bus max delivery count and lock expiry: [Service Bus dead-letter queues](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-dead-letter-queues#maximum-delivery-count).
- Designing functions for identical input: [Designing Azure Functions for identical input](https://learn.microsoft.com/azure/azure-functions/functions-idempotent); duplicate detection is a Service Bus feature, not a Storage queue one: [Storage queues and Service Bus queues — compared and contrasted](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-azure-and-service-bus-queues-compared-contrasted).

Observed:

- Exactly one processing record per blob through Event Grid redelivery (a copy of the event), a pod deleted mid-batch, a rolling restart mid-batch, 60 s without egress and malformed events, with public endpoints and through private endpoints ([02](../experiments/02-phase-1-scenarios.md), [06](../experiments/06-phase-2-scenarios.md)) (Q12).
- The polling trigger's receipts with two replicas: no blob processed twice across restarts; without a shared host ID, the record caught every repeat ([02](../experiments/02-phase-1-scenarios.md), [04](../experiments/04-scale-to-zero-host-id-probes.md)) (Q4).
