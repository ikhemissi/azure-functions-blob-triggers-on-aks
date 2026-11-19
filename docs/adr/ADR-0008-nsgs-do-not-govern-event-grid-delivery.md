# ADR-0008 — Network security groups cannot govern Event Grid's deliveries

**Status:** Accepted (2026-11-19) · **Date:** 2026-11-18

## Context

A network security group (NSG) filters traffic to and from resources in an Azure virtual network: its rules apply to subnets and network interfaces. For private endpoints, NSG rules apply only when network policies are enabled on the endpoints' subnet.

Event Grid's push deliveries ([ADR-0007](ADR-0007-securing-event-grid-delivery.md)) go from the Event Grid service to the destinations' public endpoints (Storage queue, Service Bus), in public IP space over the Microsoft backbone. Neither end of that path is in the spike's virtual network (`10.60.0.0/16`), and push delivery can't use a private endpoint. So no NSG of the virtual network sees these deliveries, whatever its rules.

## Decision

Event Grid's access to the brokers is governed by the controls that sit on its path:

1. the destination's **network rules**: public access limited to selected networks or disabled, with the trusted-services exception (Q5, Q6);
2. the **Entra roles** of each system topic's identity, at the narrowest scope accepted (Q8);
3. the **event subscription** itself: one source account, `Microsoft.Storage.BlobCreated` only, subject `/blobServices/default/containers/uploads/`.

NSGs (none in phase 1; if added in phase 2 on the `private-endpoints` subnet, with network policies enabled) and the cluster's Cilium network policies ([`k8s/network-policy.yaml`](../../k8s/network-policy.yaml)) govern only the apps' own traffic: the pods' egress (DNS and HTTPS) and, in phase 2, their calls to the private endpoints.

## Consequences

- Good: each control is placed where the traffic actually passes; no rule gives a false sense of coverage.
- Bad: a network team reviewing NSG rules won't find Event Grid's flows there; they are documented here and in the destinations' network settings.
- Bad: auditing Event Grid's writes relies on the destinations' own resource logs, not on the virtual network's logs (Q5, Q6).

## Alternatives considered

- **NSG rules naming Event Grid's addresses:** would apply only to traffic entering the virtual network, which push deliveries to Storage and Service Bus don't. Not applicable.
- **Bringing Event Grid's deliveries into the virtual network:** not possible with push delivery; pull delivery from a namespace over a private endpoint would ([ADR-0006](ADR-0006-no-event-grid-namespaces-pull-delivery.md)).

## Evidence

Documented:

- NSGs filter traffic between Azure resources in virtual networks: [Network security groups overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview).
- NSG support for private endpoints requires network policies on the subnet: [Manage network policies for private endpoints](https://learn.microsoft.com/azure/private-link/disable-private-endpoint-network-policy).
- Push delivery can't deliver to private endpoints: [Deliver events securely over a private link](https://learn.microsoft.com/azure/event-grid/consume-private-endpoints); delivery with managed identity in public IP space on the Microsoft backbone: [Deliver events securely by using managed identities](https://learn.microsoft.com/azure/event-grid/deliver-events-using-managed-identity).
- Storage network rules and trusted-service exceptions: [Firewall rules and network access control for Azure Storage](https://learn.microsoft.com/azure/storage/common/storage-network-security); Azure Monitor resource logs for the data plane: [Storage considerations — Storage logs](https://learn.microsoft.com/azure/azure-functions/storage-considerations#storage-logs).

Observed:

- Event Grid delivered with every setting tested on account 2 and on the namespace, up to public access off; the network security groups on the virtual network's subnets play no part in it ([07](../experiments/07-event-grid-destination-access.md)) (Q5, Q6).

Still to verify:

- Where Event Grid's writes show in the account's and the namespace's logs (Q5, Q6).
