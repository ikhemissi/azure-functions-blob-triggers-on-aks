# ADR-0007 — Securing Event Grid delivery to the Storage queue and to Service Bus

**Status:** Proposed · **Date:** 2026-11-18

## Context

Two Event Grid system topics push Blob events: `egst-up2-<env>` to the Storage queue `blob-events` (account 2), `egst-up3-<env>` to the Service Bus queue `blob-events`; each dead-letters to `eventgrid-deadletter` in its upload account. Storage accounts have shared keys off and Service Bus has local authentication off, so Event Grid must authenticate with a managed identity. In phase 2 the destinations are closed to public traffic: when a destination has firewall or virtual network rules, Event Grid can deliver with its **system-assigned** identity only, and only if the destination allows trusted Azure services. A user-assigned identity can't be used in that case.

## Decision

- Each system topic has a **system-assigned identity**, used for delivery and for dead-lettering (`delivery_identity`, `dead_letter_identity` in [`infra/event-grid.tf`](../../infra/event-grid.tf)).
- Roles, as deployed:

  | Identity | Role | Scope |
  |---|---|---|
  | `egst-up2` | Storage Queue Data Message Sender | account 2 |
  | `egst-up2` | Storage Blob Data Contributor (dead-letter) | account 2 |
  | `egst-up3` | Azure Service Bus Data Sender | the `blob-events` queue |
  | `egst-up3` | Storage Blob Data Contributor (dead-letter) | account 3 |

- **Observed on 2026-11-17** (azurerm provider 4.81.0, francecentral): Event Grid's check of the identity's access when the subscription was created accepted the two Storage roles only at the account scope, not on the queue nor on the dead-letter container; the Service Bus sender role on the queue was accepted. The account scope is therefore used for now; to verify again in phase 2 (Q8). [DESIGN.md](../DESIGN.md#identities-and-roles) still lists the narrower scopes and follows Q8's answer.
- Phase 2: the destinations allow **trusted Azure services** (Storage: the trusted-services exception; Service Bus Premium: *Allow trusted Microsoft services*), with public access limited to selected networks or disabled as each test of Q5 and Q6 requires.
- This is **not private endpoint traffic**: Event Grid reaches the destinations' public endpoints over an encrypted channel on the Microsoft backbone, authenticated by its identity. Private endpoints carry only the apps' own traffic (reading the queues and the blobs).

## Consequences

- Good: no keys or SAS anywhere; access is granted and revoked through Entra role assignments.
- Good: the system-assigned identities live and die with their topics, with nothing to rotate.
- Bad: on Storage, the roles are broader than one queue or one container (the whole account 2 or 3) until Q8 shows a narrower scope works.
- Bad: the destinations keep a public endpoint path open to trusted services; "fully private" holds for the apps, not for Event Grid's deliveries ([ADR-0008](ADR-0008-nsgs-do-not-govern-event-grid-delivery.md)).
- Bad: role assignments take time to apply; the subscriptions wait 120 s after them (`time_sleep`).

## Alternatives considered

- **User-assigned identity:** shareable and created ahead of the topic, but can't deliver once the destination has firewall rules. Rejected.
- **Keys or SAS:** disabled on every account and namespace by design. Rejected.
- **Pull delivery from a namespace over a private endpoint:** see [ADR-0006](ADR-0006-no-event-grid-namespaces-pull-delivery.md).

## Evidence

Documented:

- Delivery with managed identities, steps per destination, and *system-assigned only with firewall rules and trusted services*: [Deliver events securely by using managed identities](https://learn.microsoft.com/azure/event-grid/deliver-events-using-managed-identity#firewall-and-virtual-network-rules).
- Roles per destination, including Storage Blob Data Contributor for dead-lettering: [Grant managed identity the access to Event Grid destination](https://learn.microsoft.com/azure/event-grid/add-identity-roles#supported-destinations-and-azure-roles); [Use managed identities to deliver events](https://learn.microsoft.com/azure/event-grid/managed-service-identity).
- Event Grid system topics in Storage's trusted services: [Trusted Azure services — managed identity](https://learn.microsoft.com/azure/storage/common/storage-network-security-trusted-azure-services#trusted-access-based-on-a-managed-identity); Service Bus: [Trusted Microsoft services](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-service-endpoints#trusted-microsoft-services).
- Traffic on the Microsoft backbone, public IP space, managed identity: [Deliver events securely by using managed identities](https://learn.microsoft.com/azure/event-grid/deliver-events-using-managed-identity).

To verify:

- Delivery to the Storage queue with public access on, limited with trusted services, disabled (Q5).
- Delivery to the Service Bus Premium queue in the same three cases (Q6).
- The narrowest scope Event Grid accepts for each role, again in phase 2 (Q8).
