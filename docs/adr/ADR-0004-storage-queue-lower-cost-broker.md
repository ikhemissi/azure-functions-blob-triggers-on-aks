# ADR-0004 — Storage queue evaluated as the lower-cost broker

**Status:** Accepted (2026-11-19) · **Date:** 2026-11-18

## Context

The event-driven paths need a broker between Event Grid and the apps ([ADR-0003](ADR-0003-no-event-grid-blob-trigger-source.md)): it accepts Event Grid's push delivery with a managed identity, buffers the events, is reachable by the apps through a private endpoint, and gives KEDA a length to scale on. Storage queues and Service Bus queues both qualify; they differ in features and in pricing model (Storage: pay per use; Service Bus Premium: fixed price per messaging unit, see [ADR-0005](ADR-0005-service-bus-premium-for-private-endpoints.md)).

## Decision

App 2 (`queue-triggered`) uses a Storage queue (`blob-events`) in the upload account (account 2), fed by an Event Grid system topic, and is evaluated as the lower-cost option against app 3 (Service Bus). Poison messages go to the trigger's `blob-events-poison` queue; malformed events are logged and completed.

## Consequences

- Good: no extra service: the queue lives in a storage account the scenario already has, with the same private endpoints (`queue` sub-resource) and Entra-only access.
- Good: expected lowest fixed cost; to verify against Service Bus (Q13).
- Bad: no automatic dead-lettering and no duplicate detection: the Functions queue trigger's poison queue and the app's idempotency record ([ADR-0009](ADR-0009-at-least-once-and-idempotency.md)) take their place.
- Bad: message encoding must match between Event Grid and the trigger: the Functions queue trigger expects Base64 by default; what Event Grid writes is to verify (Q5).
- Bad: messages up to 64 KB (48 KB with Base64 encoding): fine for one event per message, a limit for anything larger.

## Alternatives considered

- **Service Bus queue:** dead-letter queue, duplicate detection, sessions; Premium needed for private endpoints. Evaluated as app 3 ([ADR-0005](ADR-0005-service-bus-premium-for-private-endpoints.md)).
- **Event Hubs:** also an Event Grid handler, but not one of the brief's options.
- **A separate storage account for the queue:** isolates queue traffic from uploads, at the cost of one more account and endpoint set. Not needed for the spike.

## Evidence

Documented:

- Storage queues compared with Service Bus queues (no automatic dead-lettering, no duplicate detection, 64 KB messages): [Storage queues and Service Bus queues — compared and contrasted](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-azure-and-service-bus-queues-compared-contrasted).
- Storage queue as an Event Grid handler, with managed identity delivery and a dead-letter destination: [Storage queue as an event handler](https://learn.microsoft.com/azure/event-grid/handler-storage-queues).
- Queue trigger: Base64 expected by default ([Usage](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-queue-trigger#usage)); five attempts then `<queue>-poison` ([Poison messages](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-queue-trigger#poison-messages)).
- Private endpoints for Storage queues: [Use private endpoints for Azure Storage](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints).
- Service Bus Premium has fixed pricing, Standard pay-as-you-go: [Service Bus Premium and Standard tiers](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-premium-messaging).

Observed:

- Event Grid delivered into the queue with the account's public access on, limited to no networks with trusted services, and off; messages arrive Base64-encoded ([07](../experiments/07-event-grid-destination-access.md)) (Q5).
- KEDA's `azure-queue` scaler with Workload Identity scaled app 2 out (bounded by the nodes), back, and to zero and back ([02](../experiments/02-phase-1-scenarios.md), [04](../experiments/04-scale-to-zero-host-id-probes.md)) (Q7).
- Duplicates processed once; undecodable messages poisoned; malformed events completed and logged ([02](../experiments/02-phase-1-scenarios.md), [06](../experiments/06-phase-2-scenarios.md)) (Q12).
- About €1.58 a month of its own at a million blobs (€2.04 polled every 2 s), against €608 for Service Bus Premium with private endpoints ([08](../experiments/08-costs.md)) (Q13). It is the spike's answer to Q1, with `maxPollingInterval` lowered ([03](../experiments/03-queue-polling-interval.md)).
