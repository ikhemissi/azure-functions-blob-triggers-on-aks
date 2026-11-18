# ADR-0002 — Replicas of one Deployment share one host ID

**Status:** Proposed · **Date:** 2026-11-18

## Context

On AKS one app runs as several pods (replicas) of one Deployment. The Functions host keeps its state in the host storage account under the host ID: the polling Blob trigger's *blob receipts* (which blob version was processed) and its *scan info* (`azure-webjobs-hosts`); the lock (a lease) that keeps the blob scan a singleton across instances is expected there too (to verify, Q3, Q4). The replicas of one app coordinate only if they find the same state under the same ID.

Outside App Service the host has no site name to derive the ID from. In the host's source (commit [`2e401ef`](https://github.com/Azure/azure-functions-host/blob/2e401ef5816d52eec09d574839787bb2d043a012/src/WebJobs.Script/Host/ScriptHostIdProvider.cs#L74-L103)), when no ID is configured:

- if `KUBERNETES_SERVICE_HOST` and `POD_NAMESPACE` are set, the host takes the pod for App Service on Kubernetes: it derives the ID from `WEBSITE_SITE_NAME`, which our pods don't set, and uses a lock manager that needs that platform's leader endpoint (with `POD_NAMESPACE` set, the blob trigger's listener failed to start on 2026-11-18, so our Deployments no longer set it);
- otherwise it derives the ID from the machine name (the pod name) and a hash of the script path, a path the source comment marks as for local use only, not distributed scenarios.

## Decision

Every replica of an app gets the same explicit host ID through `AzureFunctionsWebHost__hostid` (the app's name, see [DESIGN.md](../DESIGN.md#names)), set in the Deployment's pod template, so that it never depends on the pod's name or on variables a Kubernetes platform may or may not set.

## Consequences

- Good: the replicas share one set of receipts and scan info.
- Good: a pod restart or a rolling deployment keeps the ID, so existing blobs are not processed again.
- Bad: changing the host ID, or the host storage account, starts from empty state: the polling Blob trigger may process blobs that were processed before. Such a change is a migration, not a setting change.
- Bad: the ID is managed by hand; two apps must never reuse it on a shared host storage account ([ADR-0001](ADR-0001-three-independent-function-apps.md)).

## Alternatives considered

- **No explicit host ID:** depends on the source paths above; each replica may get its own ID (pod name) or none. Rejected: the outcome is to verify (Q3) and either way the replicas would not share state.
- **One replica per app:** avoids the question for the polling app, but removes the test of two replicas sharing the singleton scan (Q4) and the availability of a second pod.

## Evidence

Documented:

- Blob receipts and scan info are stored in `azure-webjobs-hosts` in the host storage account: [Blob trigger — Blob receipts](https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-blob-trigger#blob-receipts).
- Changing the host ID or the host storage account can make the Blob trigger process blobs again: [Storage considerations — Avoiding host ID collisions](https://learn.microsoft.com/azure/azure-functions/storage-considerations#avoiding-host-id-collisions).
- Default host ID in a Kubernetes environment: [`ScriptHostIdProvider.cs` L74–L103](https://github.com/Azure/azure-functions-host/blob/2e401ef5816d52eec09d574839787bb2d043a012/src/WebJobs.Script/Host/ScriptHostIdProvider.cs#L74-L103); detection of Kubernetes: [`EnvironmentExtensions.cs` L465](https://github.com/Azure/azure-functions-host/blob/2e401ef5816d52eec09d574839787bb2d043a012/src/WebJobs.Script/Environment/EnvironmentExtensions.cs#L465) (source read on 2026-11-17).

To verify:

- The two replicas of `blob-polling` share the host ID, the receipts and one singleton scan, and where the scan's lock lives (Q3, Q4).
- What the host does on AKS without an explicit host ID, with and without `POD_NAMESPACE` (Q3).
- What happens to existing blobs when the host ID or the host storage account changes (Q3).
