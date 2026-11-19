# 07 — Event Grid destination access

**Date:** 2026-11-19 · **Answers:** Q5, Q6 · **Versions:** [00](00-environment.md)

## Goal

Find how far the public access of Event Grid's destinations (upload accounts 2 and 3, whose queue and dead-letter container it writes to, and the Service Bus namespace) can be restricted while Event Grid still delivers: the three values of `EVENT_GRID_DESTINATION_ACCESS` ([DESIGN](../DESIGN.md#phase-2-network)).

## Setup

Phase 2 as in [06](06-phase-2-scenarios.md). For each value, the destinations' settings were applied with Terraform, then scenarios 1, 2, 4 and 8 ran on the jumpbox (scenarios 1 and 2 go through Event Grid; 4 and 8 put messages into the queues directly). Event Grid's system topics have managed identities with the destination roles of [01](01-making-phase-1-run.md); storage has the `AzureServices` bypass and a resource instance rule per system topic, and Service Bus its trusted-services bypass, in every mode. Access from outside the virtual network was tried from a laptop with the tester's identity, which has the data roles.

## Results

| Value | Upload accounts 2 and 3 | Service Bus | Event Grid delivered | Scenarios 1, 2, 4, 8 | From outside |
|---|---|---|---|---|---|
| `enabled` | public, all networks | public, all networks | yes | passed (06) | allowed |
| `trusted` | public access on, default action Deny, no IP or network rules | public access off (see below) | yes | passed | refused: storage "blocked by network rules", Service Bus HTTP 401 "Ip has been prevented to connect to the endpoint" |
| `disabled` | public access off | public access off | yes: no failed delivery attempt in the system topics' metrics, during the run and 10 minutes after the change | passed, twice | refused |

Latency doesn't depend on the value: median for 20 concurrent blobs, Service Bus 1.1 to 1.8 s, Storage queue 1.8 to 20.9 s (its polling backoff), polling trigger 3.5 to 12.7 s (its 10 s scan), over the four runs of scenario 2 in this experiment.

**Service Bus and the `trusted` shape.** Setting default action Deny with no IP or virtual network rules while public access is on was refused: `InvalidNetworkRuleSetUpdate`, "This would render the namespace resources inaccessible for data-plane requests. If the intention was to restrict data-plane requests to private links only, please set the PublicNetworkAccess property to Disabled." So `trusted` turns the namespace's public access off, as `disabled` does. With public access off, the namespace reports default action Allow whatever was sent; the Terraform now sends Allow, so that plans show no change.

## Conclusion

- **Q6:** Event Grid delivered into the Storage queue and into Service Bus with every restriction tested, up to public access off on the destinations, while clients outside the virtual network were refused. Delivery relied on the system topics' managed identities and the trusted-service settings; the private endpoints carry the apps' own traffic.
- **Q5:** messages arrive in the Storage queue Base64-encoded in every mode (scenario 4); malformed events behave as in phase 1 (scenario 8).
- **Default:** `disabled` is the most restrictive value and worked; the spike leaves the environment in it. `trusted` keeps the storage accounts' public endpoint reachable for allowed networks, should IP or network rules be added later.
- Not tested: Event Grid's own dead-lettering into the restricted accounts, which needs a delivery that fails.
