# 01 — Making phase 1 run

**Date:** 2026-11-17 and 18 · **Answers:** Q2, Q3, Q4, Q8, Q10 · **Versions:** [00](00-environment.md)

## Goal

Provision and deploy phase 1 as designed, and record every change the first deployment needed, with its cause.

## Setup

[docs/DESIGN.md](../DESIGN.md) as of 2026-11-17, `azd up` from a laptop.

## Steps and results

| # | Symptom | Cause | Change |
|---|---|---|---|
| 1 | `azurerm_storage_table` failed: "Key based authentication is not permitted" | the provider sets a table's access policies through the data plane with the account key; shared keys are off | tables created through Resource Manager with azapi (`Microsoft.Storage/storageAccounts/tableServices/tables`) |
| 2 | a role assignment failed on the Storage queue's ID | `azurerm_storage_queue` created by account name has a data-plane URL as its ID | queue created with `storage_account_id` |
| 3 | Event Grid subscription creation failed: "Managed identity … does not have authorization to deliver to the endpoint" (Storage queue) and "… to the deadletter endpoint" (Service Bus) | Event Grid checks its identity's access when the subscription is created. With *Storage Queue Data Message Sender* on the queue and *Storage Blob Data Contributor* on the dead-letter container, the check failed for over ten minutes; with the same roles on the storage account, it passed. *Azure Service Bus Data Sender* on the queue passed. | Storage roles of the Event Grid identities on the account (Q8); the subscriptions wait 120 s after their role assignments |
| 4 | `replicas` refused as a string | azd renders only `*.tmpl.yaml` manifests (Go templates, `{{ .Env.NAME }}`); other manifests are applied as they are | manifests using azd values renamed `*.tmpl.yaml` |
| 5 | blob-polling's listener failed: "The 'file' scheme is not supported" | with `KUBERNETES_SERVICE_HOST` and `POD_NAMESPACE` both set, the host runs as on App Service on Kubernetes and uses a lock manager needing that platform's leader endpoint | `POD_NAMESPACE` removed from the Deployments (Q3) |
| 6 | Service Bus trigger: "Connection timed out" | the namespace's default egress policy allowed DNS and HTTPS only; the trigger uses AMQP (TCP 5671) | a policy allowing TCP 5671 for that app's pods |
| 7 | a blob uploaded after the host started was not processed after 10 minutes; the container scan re-listed an older blob every 10 s | WebJobs blob extension 5.3.8 (brought by Worker.Extensions.Storage.Blobs 6.8.2): without Storage Analytics logs, the scan didn't start new sweeps; the 5.3.10 release notes list the fix (Azure/azure-sdk-for-net#61660, #62763) | the host's blob extension pinned to 5.3.10 through an `ExtensionInformation` attribute in a referenced library (`src/BlobExtensionVersion`), Q4 |
| 8 | only startup logs reached Application Insights; metrics arrived | the Azure Monitor exporter drops logs whose trace isn't sampled (`EnableTraceBasedLogsSampler`, true by default), and the trace the host passes to the worker arrives unsampled while the host doesn't run OpenTelemetry | the sampler turned off in the apps |
| 9 | a tenant policy turned on Microsoft Defender for the cluster | — | `ignore_changes` on `microsoft_defender` |
| 10 | kubectl refused (TLS handshake reset) from 14:25 | a VPN on the laptop routed Azure address ranges through its own exit IP, outside the API server's authorized range | VPN off during the tests; in phase 2 the API server is reached from inside the virtual network |

Other observations:
- The Functions host logs a warning for an explicit host ID: "Host id explicitly set in configuration. This is not a recommended configuration and may lead to unexpected behavior." The design sets one on purpose ([ADR-0002](../adr/ADR-0002-replicas-share-one-host-id.md)).
- The deployer needs data roles to run the tests (upload blobs, put messages, read the processing tables), now in `infra/tester-roles.tf`.
- Without Storage Analytics logs on the upload account, the polling trigger logs "Storage Analytics Logs are not enabled on the target blob storage account" and works from container scans only.

## Conclusion

Workload Identity works for the host's own storage and for the three triggers with `__credential=workloadidentity` (Q2: yes, phase 1). Each app runs with its explicit host ID shared by its replicas (Q3, partly: what happens without one is still to test). The anonymous `/admin/host/ping` probes keep the pods ready (Q10, partly: behaviour while the host starts is still to measure).
