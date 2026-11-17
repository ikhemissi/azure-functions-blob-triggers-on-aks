# ADR-0006 — Event Grid namespaces with pull delivery are not in this first spike

**Status:** Proposed · **Date:** 2026-11-18

## Context

Event Grid has two delivery models. **Push** (Event Grid basic, system topics) sends events to a handler: a webhook, a Storage queue, a Service Bus queue, Event Hubs. **Pull** is a feature of Event Grid namespaces: a consumer *receives* events from a namespace topic's queue subscription, then *acknowledges*, *releases* or *rejects* them with lock tokens, and can do so over a private endpoint of the namespace. Push delivery can't deliver to private endpoints; pull delivery can be consumed over a private link.

Pull delivery would remove the broker between Event Grid and the apps ([ADR-0004](ADR-0004-storage-queue-lower-cost-broker.md), [ADR-0005](ADR-0005-service-bus-premium-for-private-endpoints.md)), but needs a consumer of its own.

## Decision

The first spike does not include Event Grid namespaces. It compares the three options of the brief (polling Blob trigger, Event Grid to a Storage queue, Event Grid to Service Bus), which use the Blob, Queue and Service Bus triggers of the Functions host and the KEDA scalers the AKS add-on provides.

## Consequences

- Good: the spike stays within its time box and its three options, with triggers and scalers that are already part of the setup.
- Bad: a model that keeps the event path private end to end (consumer to namespace over a private endpoint) is not measured.
- Bad: if the brokers' trusted-services paths prove unsuitable in phase 2 ([ADR-0007](ADR-0007-securing-event-grid-delivery.md)), this is the first option to examine next.

## Alternatives considered

- **A fourth app pulling from an Event Grid namespace:** its own receive / acknowledge / release loop, its own scaling signal, and a way to get the storage account's events into a namespace topic. Deferred to a follow-up spike: new code, new questions, outside the time box.

## Evidence

Documented:

- Pull delivery: receive, acknowledge, release, reject, lock tokens, private link: [Pull delivery with HTTP](https://learn.microsoft.com/azure/event-grid/pull-delivery-overview).
- Pull supports private links; push does not deliver to private endpoints: [Deliver events securely over a private link](https://learn.microsoft.com/azure/event-grid/consume-private-endpoints).
- Namespaces: [Event Grid namespace concepts](https://learn.microsoft.com/azure/event-grid/concepts-event-grid-namespaces).

To verify:

- Nothing in this spike: recorded under "What we would do differently" in the findings, as an open point for Q1 (which option works best with private networking).
