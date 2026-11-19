# ADR-0005 — Service Bus Premium for private endpoints, Standard while the endpoints are public

**Status:** Accepted (2026-11-19) · **Date:** 2026-11-18

## Context

App 3 (`servicebus-triggered`) reads Blob events from a Service Bus queue fed by Event Grid. Phase 2 needs every service on private endpoints. Service Bus supports private endpoints and virtual network service endpoints only in the Premium tier; the Standard tier supports IP firewall rules but not the *trusted Microsoft services* exception. Premium is priced per messaging unit (fixed), Standard per use.

## Decision

The namespace's tier follows the phase (`var.private_networking` in [`infra/service-bus.tf`](../../infra/service-bus.tf)):

- **Phase 1 (public endpoints): Standard**, public network access on, local (SAS) authentication off, Entra roles only.
- **Phase 2 (private): Premium**, with a private endpoint and private DNS (`privatelink.servicebus.windows.net`), public network access off or limited to trusted services as each Event Grid test needs ([ADR-0007](ADR-0007-securing-event-grid-delivery.md)).

The queue is the same in both (`blob-events`, max delivery count 5, dead-lettering on expiry).

## Consequences

- Good: phase 1 proves the app, the trigger, KEDA and Workload Identity at a low cost before paying for Premium.
- Good: the only change between the phases is the tier and the network; the code and the queue don't change.
- Bad: phase 1 does not measure Premium's latency or throughput; phase 2 must repeat the measurements (Q9).
- Bad: Premium has a fixed monthly cost per messaging unit while it exists, used or not (Q13).
- Bad: changing the tier may replace the namespace and its queue in Terraform: to verify in the plan when phase 2 starts (Q6).

## Alternatives considered

- **Premium from phase 1:** same tier in both phases, but pays for Premium during the phase that doesn't need it.
- **Standard with IP firewall rules in phase 2:** no private endpoint, and no trusted-services exception for Event Grid. Rejected: doesn't meet the brief's private networking.
- **Storage queue only:** see [ADR-0004](ADR-0004-storage-queue-lower-cost-broker.md); the spike compares both.

## Evidence

Documented:

- Private endpoints are a Premium feature: [Private endpoints for Service Bus](https://learn.microsoft.com/azure/service-bus-messaging/private-link-service); service endpoints and private endpoints Premium only: [Network security for Service Bus](https://learn.microsoft.com/azure/service-bus-messaging/network-security).
- Standard supports IP filtering but not the trusted services option: [Service Bus IP firewall](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-ip-filtering).
- Premium: messaging units, fixed pricing: [Service Bus Premium and Standard tiers](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-premium-messaging).
- Max delivery count and the dead-letter queue: [Service Bus dead-letter queues — Maximum delivery count](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-dead-letter-queues#maximum-delivery-count).

Observed:

- Event Grid delivered into the Premium queue with public access on and off; the "limited, no rules" shape is refused by the namespace, so it is public access off ([07](../experiments/07-event-grid-destination-access.md)) (Q6).
- The phase change replaced the namespace under the same name (`sku` and `premium_messaging_partitions` force a new resource), with its queue and role assignments; the apps reconnected without a change ([05](../experiments/05-making-phase-2-run.md)) (Q6).
- Latency was the same with Standard and Premium, median 0.9 to 1.9 s for 20 blobs ([02](../experiments/02-phase-1-scenarios.md), [06](../experiments/06-phase-2-scenarios.md)) (Q9); one Premium messaging unit is about €608 a month, Standard €9 plus operations ([08](../experiments/08-costs.md)) (Q13).
