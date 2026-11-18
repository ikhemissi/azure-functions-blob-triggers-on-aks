# ADR-0001 — Three independent Function apps with three unique Functions host IDs

**Status:** Proposed · **Date:** 2026-11-18

## Context

The spike compares three triggers (polling Blob trigger, Storage queue, Service Bus) under the same conditions: private networking, identity-only access, KEDA scaling. The Functions host uses a *host ID* to identify an app in its storage: the runtime keeps per-app tracking data (such as the Blob trigger's receipts) under this ID. Two apps with the same host ID on the same storage account collide; in runtime 4.x the host logs an error and stops.

## Decision

Three separate Function apps, one per trigger (`blob-polling`, `queue-triggered`, `servicebus-triggered`; see [DESIGN.md](../DESIGN.md#names)), each with:

- its own container image, Kubernetes Deployment and service account;
- its own user-assigned identity, federated through Workload Identity, with roles only on its own resources;
- its own host storage account (`st<c>host1..3<token>`);
- an explicit, unique host ID set by `AzureFunctionsWebHost__hostid` (equal to the app's name).

## Consequences

- Good: each trigger is measured alone (latency, scaling, cost); a failure or a scaling burst in one does not affect the others.
- Good: each identity holds the least roles for one trigger, so Q8 can be answered per trigger.
- Good: unique host IDs keep the apps safe even if they later share a host storage account.
- Bad: three images, three Deployments and three host accounts to build, deploy and pay for.
- Bad: a change to the shared processing code (`src/BlobProcessing`) is built and deployed three times.

## Alternatives considered

- **One Function app with three functions:** one host and one scale unit; KEDA would scale the three triggers together, and one identity would hold every role. Rejected: the comparison would not be independent.
- **Three apps on one shared host storage account:** possible with unique host IDs, but host-storage traffic and any problem would mix between the apps. Rejected for the spike.
- **Default (generated) host IDs:** see [ADR-0002](ADR-0002-replicas-share-one-host-id.md).

## Evidence

Documented:

- The host ID identifies an app in its storage, the default is derived from the app name truncated to 32 characters, and a collision stops the host in runtime 4.x: [Storage considerations — Host ID considerations](https://learn.microsoft.com/azure/azure-functions/storage-considerations#host-id-considerations).
- `AzureFunctionsWebHost__hostid` overrides the generated ID; 1 to 32 lowercase letters, digits and dashes: [App settings reference — AzureFunctionsWebHost__hostid](https://learn.microsoft.com/azure/azure-functions/functions-app-settings#azurefunctionswebhost__hostid).

To verify:

- Each app's host runs with Workload Identity only, for its own storage and its trigger, with no keys (Q2).
- Each app's host uses its explicit host ID in its host storage, and the replicas of one app share it (Q3).
- The least roles each app's identity needs (Q8).
