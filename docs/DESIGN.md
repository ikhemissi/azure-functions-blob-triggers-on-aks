# Design

The contract every part of the spike follows: names, settings, identities, roles and who owns which files. Change it here first, in its own commit, then in the code; a name used in two places must match this page.

## What we compare

Three Azure Functions apps (.NET 10, isolated worker, in Linux containers on AKS), each triggered when a blob lands in its own storage account:

| App | Trigger | Path of a new blob | Scaling |
|---|---|---|---|
| `blob-polling` | Blob trigger, polling (not the Event Grid source) | account 1 → the host scans the container | fixed replicas (2), no KEDA ([why](#scaling)) |
| `queue-triggered` | Queue trigger | account 2 → Event Grid system topic → Storage queue → app | KEDA, `azure-queue` scaler |
| `servicebus-triggered` | Service Bus trigger | account 3 → Event Grid system topic → Service Bus queue → app | KEDA, `azure-servicebus` scaler |

## Phases

1. **Public endpoints, own virtual network** (`PRIVATE_NETWORKING=false`, the default): AKS nodes in our subnet, the API server public but limited to the deployer's IP (`AKS_AUTHORIZED_IP_RANGES`), storage, Service Bus (Standard) and the registry (Basic) on public endpoints with Entra authentication only (no keys, no SAS, no connection strings). `azd up` from a laptop. Proves the apps, Workload Identity, host IDs, KEDA and the trigger behaviour.
2. **Private** (`PRIVATE_NETWORKING=true`): private endpoints and private DNS for every storage account (the services its clients use, see [Phase 2 network](#phase-2-network)), Service Bus (Premium) and the registry (Premium); public network access off or limited to trusted services, as each Event Grid test allows (`EVENT_GRID_DESTINATION_ACCESS`); the API server private; deployment and administration through a Bastion jumpbox in the virtual network. The same tests run again.
3. **Comparison:** the table in the README from measured results, the cost, the ADRs.

Every setting that differs between the phases depends on `var.private_networking` in Terraform; nothing else changes between them.

## Names

`<env>` is the azd environment name (`AZURE_ENV_NAME`), `<token>` the 8-character token from `infra/main.tf` (`local.token`), `<c>` `local.compact_name`. Storage account names are lowercase letters and digits, 24 at most.

| Thing | Name |
|---|---|
| Kubernetes namespace | `functions` |
| Apps (Deployment, service account, label `app`, azd service, `src/` folder) | `blob-polling` (`src/BlobPollingFunction`), `queue-triggered` (`src/QueueTriggeredFunction`), `servicebus-triggered` (`src/ServiceBusTriggeredFunction`) |
| Functions host IDs (`AzureFunctionsWebHost__hostid`) | `blob-polling`, `queue-triggered`, `servicebus-triggered` (≤ 32 characters, unique, identical across the replicas of one app) |
| Label for the trigger type | `trigger: blob-polling` / `storage-queue` / `service-bus` |
| Business (upload) storage accounts | `st<c>up1<token>`, `st<c>up2<token>`, `st<c>up3<token>`, each with a blob container `uploads` |
| Host storage accounts (one per app) | `st<c>host1<token>`, `st<c>host2<token>`, `st<c>host3<token>` |
| Storage queue (account 2) | `blob-events` (the trigger's poison queue: `blob-events-poison`) |
| Service Bus namespace / queue | `sb-<env>-<token>` / `blob-events` (max delivery count 5, dead-lettering on expiry) |
| Event Grid system topics | `egst-up2-<env>`, `egst-up3-<env>`; subscriptions `to-storage-queue`, `to-service-bus` |
| Event Grid dead-letter container | `eventgrid-deadletter` in accounts 2 and 3 |
| Processing records (idempotency) | table `processed` in each app's host account |
| User-assigned identities (one per app) | `id-blob-polling-<env>`, `id-queue-triggered-<env>`, `id-servicebus-triggered-<env>` |
| AKS cluster / registry | `aks-<env>-<token>` / `cr<c><token>` |

## Address plan

Virtual network `10.60.0.0/16`:

| Subnet | Prefix | Use |
|---|---|---|
| `aks-nodes` | `10.60.0.0/22` | node pool (Azure CNI Overlay, pods in `192.168.0.0/16`) |
| `aks-api-server` | `10.60.4.0/28` | API Server VNet Integration (delegated to `Microsoft.ContainerService/managedClusters`) |
| `private-endpoints` | `10.60.5.0/24` | phase 2 |
| `AzureBastionSubnet` | `10.60.6.0/26` | the Bastion host of a working session ([Private access](#private-access)) |
| `jumpbox` | `10.60.6.64/27` | the jumpbox; no default outbound access |

## Phase 2 network

What `PRIVATE_NETWORKING=true` changes; with `false`, none of it exists and everything stays as in phase 1. The private DNS zones (`privatelink.{blob,queue,table}.core.windows.net`, `privatelink.servicebus.windows.net`, `privatelink.azurecr.io`) exist only in phase 2, linked to the virtual network.

| Resource | Private endpoints (`pe-<resource>[-<service>]`, in `private-endpoints`) | Public network access |
|---|---|---|
| Host accounts 1 to 3 | blob, queue, table | disabled |
| Upload account 1 | blob, queue | disabled |
| Upload account 2 (queue `blob-events`, `eventgrid-deadletter`) | blob, queue | `EVENT_GRID_DESTINATION_ACCESS` |
| Upload account 3 (`eventgrid-deadletter`) | blob | `EVENT_GRID_DESTINATION_ACCESS` |
| Service Bus namespace (Premium, 1 messaging unit) | namespace | `EVENT_GRID_DESTINATION_ACCESS` |
| Registry (Premium) | registry | disabled; trusted services bypass the network rules; phase 2 images are built on the jumpbox, as the registry refuses azd's remote build ([05](experiments/05-making-phase-2-run.md)) |
| AKS API server | (API Server VNet Integration) | private, no authorized IP ranges |

`EVENT_GRID_DESTINATION_ACCESS` (phase 2 only, default `trusted`) is what Event Grid delivers into (Q5, Q6):

| Value | Public network access | Default action | Bypass |
|---|---|---|---|
| `enabled` | enabled, all networks | Allow | storage `AzureServices` and a resource instance rule per Event Grid system topic; Service Bus trusted services |
| `trusted` | enabled, selected networks, no IP or virtual network rules | Deny | the same |
| `disabled` | disabled | Deny | the same (not claimed to work until an experiment shows it) |

Network security groups (`nsg-aks-nodes-<env>`, `nsg-private-endpoints-<env>`) on `aks-nodes` and `private-endpoints`: allow what the cluster (nodes, pods, the API server subnet, Azure Load Balancer) and the private endpoints (HTTPS, AMQP from the virtual network) need, deny the rest inbound from the internet. `AzureBastionSubnet` and `jumpbox` get theirs with the Bastion block.

## Private access

`infra/bastion-on-demand.tf` (in both phases): a jumpbox without a public IP (`jumpbox-<env>`, Entra ID sign-in, size `JUMPBOX_SIZE`), the public IPs of a Bastion host and of a NAT Gateway, and a reaper function (azd service `bastion-reaper`, Flex Consumption). `infra/scripts/bastion-up.sh <hours>` creates an Azure Bastion Standard and a NAT Gateway for a working session; the reaper deletes both once the session's time has passed and deallocates the jumpbox. Between sessions, only the jumpbox's disk, the two addresses and the reaper's storage cost anything.

In phase 2, the API server and the registry are private: `kubectl` and `azd deploy` run on the jumpbox (`infra/scripts/bastion-ssh.sh`), whose tools `infra/scripts/jumpbox-install-tools.sh` installs once. Settings: `JUMPBOX_SIZE` (default `Standard_D2als_v7`), `JUMPBOX_LOGIN_OBJECT_IDS` (others who may sign in, comma-separated), `REAPER_DEALLOCATES_JUMPBOX` (default `true`).

## AKS

- Free tier, Kubernetes 1.37 (or the newest the region offers), one system node pool of 2 × `Standard_D2als_v7` (`AKS_NODE_SIZE`; the test subscription has no B-series).
- Azure CNI Overlay with Cilium (network policies), OIDC issuer and Workload Identity on, the KEDA add-on on (`workload_autoscaler_profile.keda_enabled`).
- Entra ID with Azure RBAC, local accounts off; the deployer gets *Azure Kubernetes Service RBAC Cluster Admin*.
- API Server VNet Integration on, public access limited to `AKS_AUTHORIZED_IP_RANGES` in phase 1, private in phase 2.
- The kubelet identity is a user-assigned identity created in `aks.tf` (no data source: `azd down` deletes the resource group before Terraform's destroy reads anything), with *AcrPull* on the registry.

## Identities and roles

One user-assigned identity per app, federated with its service account (`system:serviceaccount:functions:<app>`) and with KEDA's operator (`system:serviceaccount:kube-system:keda-operator`), so that each app's `TriggerAuthentication` uses the app's own identity (`podIdentity.provider: azure-workload`, `identityId: <client id>`).

| Identity | Scope | Roles |
|---|---|---|
| every app | its host account | Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor |
| every app | Application Insights | Monitoring Metrics Publisher |
| `blob-polling` | account 1 | Storage Blob Data Owner, Storage Queue Data Contributor (poison blobs) |
| `queue-triggered` | account 2 | Storage Queue Data Contributor (reads, deletes and writes poison messages; also KEDA's queue length), Storage Blob Data Reader |
| `servicebus-triggered` | the Service Bus queue | Azure Service Bus Data Receiver (KEDA's message count: to verify, see Q8) |
| `servicebus-triggered` | account 3 | Storage Blob Data Reader |
| Event Grid system topic 2 (system-assigned) | account 2 | Storage Queue Data Message Sender, Storage Blob Data Contributor (dead-letter). On the account: Event Grid's check at subscription creation refused them on the queue and on the container ([01](experiments/01-making-phase-1-run.md)) |
| Event Grid system topic 3 (system-assigned) | the Service Bus queue; account 3 | Azure Service Bus Data Sender (on the queue); Storage Blob Data Contributor (dead-letter, on the account, as above) |

Add a role only when Azure refuses (403) and record which call needed it. Storage accounts have shared keys off; Service Bus has local authentication off.

## App settings (environment variables in the Deployments)

Common to the three apps:

| Variable | Value |
|---|---|
| `AzureFunctionsWebHost__hostid` | the app's host ID |
| `AzureWebJobsStorage__accountName` | its host account |
| `AzureWebJobsStorage__credential` | `workloadidentity` |
| `AzureWebJobsStorage__clientId` | its identity's client ID (also `AZURE_CLIENT_ID`, injected by Workload Identity) |
| `FUNCTIONS_WORKER_RUNTIME` | `dotnet-isolated` |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | from Terraform (not a secret; the exporter authenticates with the identity) |
| `PROCESSED_TABLE_URI` | `https://<host account>.table.core.windows.net/processed` |
| `UPLOADS_BLOB_SERVICE_URI` | apps 2 and 3: `https://<their upload account>.blob.core.windows.net/`; an event whose blob URL is elsewhere is rejected as malformed |
| `POD_NAME` | from the downward API. Not `POD_NAMESPACE`: with it and `KUBERNETES_SERVICE_HOST`, the Functions host takes the pod for App Service on Kubernetes and uses a lock manager that needs that platform's leader endpoint; the blob trigger's listener then fails to start (seen 2026-11-18) |

Trigger connections (the binding's `Connection` property is the prefix):

| App | Connection | Settings |
|---|---|---|
| `blob-polling` | `UploadsStorage` | `UploadsStorage__blobServiceUri`, `UploadsStorage__queueServiceUri`, `UploadsStorage__credential=workloadidentity`, `UploadsStorage__clientId` |
| `queue-triggered` | `BlobEventsQueue` | `BlobEventsQueue__queueServiceUri`, `__credential`, `__clientId`; queue name `blob-events` |
| `servicebus-triggered` | `BlobEventsServiceBus` | `BlobEventsServiceBus__fullyQualifiedNamespace`, `__credential`, `__clientId`; queue name `blob-events` |

Apps 2 and 3 read the blob named in the event with `BlobServiceClient` and the same `WorkloadIdentityCredential` (through `DefaultAzureCredential`).

## Processing (the same in the three apps)

1. Validate the input: for Event Grid events (apps 2 and 3), event type `Microsoft.Storage.BlobCreated`, subject `/blobServices/default/containers/uploads/blobs/<name>`, the URL's account and container; malformed input is logged and not retried (app 2: completes; app 3: dead-lettered with a reason).
2. Read the blob's properties (size, ETag, version ID if any) and its first 1 KB.
3. Idempotency key: `<account>/<container>/<blob name>/<ETag or version ID>/process`; once the blob was read, insert one entity in the `processed` table (partition key: the app; row key: a SHA-256 hex of the key). A `409 Conflict` means already processed: log it as a duplicate. Recording after the work means a crash before it leads to a retry, never to a lost blob.
4. Log one structured line per step (JSON console logs and OpenTelemetry to Application Insights) with: app, trigger, blob name, URI, size, ETag/version, event time (Event Grid) or trigger time, start and end of processing, pod name, invocation ID, `idempotencyKey`, `duplicate` (true/false), `latencyMs` (end of processing minus the blob's creation time).

Shared code (event parsing, idempotency, logging fields) lives in `src/BlobProcessing`, referenced by the three apps.

## Health probes

The Functions host listens on port 80. Liveness and readiness: `GET /admin/host/ping` (anonymous). Whether it fails while the host starts is an open question (Q10); a startup probe gives the host time to start.

## Scaling

- `blob-polling`: no KEDA scaler counts *new* blobs, and the host's scan runs as a singleton, so 2 fixed replicas (`BLOB_POLLING_REPLICAS`), sharing the host ID.
- `queue-triggered`, `servicebus-triggered`: KEDA `ScaledObject`, min `KEDA_MIN_REPLICAS` (default 1; 0 tested once), max `KEDA_MAX_REPLICAS` (default 10), target 5 messages per replica (`KEDA_MESSAGES_PER_REPLICA`).

## Files and owners

| Area | Files | Owner |
|---|---|---|
| Apps | `src/**`, `tests/**`, `BlobTriggers.slnx`, `src/*/Dockerfile` | issue "Function apps" |
| Infrastructure | `infra/*.tf` except `main.tf`, `providers.tf`, `monitoring.tf` (block files), `infra/modules/<new>/`, `infra/tests/`, `infra/main.tfvars.json` | issue "Infrastructure, phase 1"; phase 2 parts: issue "Phase 2 infrastructure" |
| Kubernetes and azd | `k8s/<app>/*.yaml`, `azure.yaml` (`services:`), `infra/hooks/postdeploy/`, `scripts/*.sh`, `Makefile` | issue "Kubernetes, azd and test scripts" |
| CI | `.github/workflows/ci.yml` | after the three above |
| Docs, questions, experiments | `docs/**`, `README.md` | the maintainer |

`infra/network.tf` sets `local.network.subnet_ids` and `local.network.subnet_address_prefixes` straight from the network module's outputs (keyed by subnet name, as the shared blocks expect), and code reads `local.network.subnet_ids["aks-nodes"]`.

Terraform outputs (azd values) the Kubernetes manifests and scripts read: `AKS_NAME`, `AZURE_AKS_CLUSTER_NAME`, `AZURE_CONTAINER_REGISTRY_ENDPOINT`, `UPLOADS_ACCOUNT_1..3`, `HOST_ACCOUNT_1..3`, `SERVICE_BUS_NAMESPACE`, `<APP>_CLIENT_ID` (`BLOB_POLLING_CLIENT_ID`, `QUEUE_TRIGGERED_CLIENT_ID`, `SERVICEBUS_TRIGGERED_CLIENT_ID`), `APPLICATIONINSIGHTS_CONNECTION_STRING`, `BLOB_POLLING_REPLICAS`, `KEDA_MIN_REPLICAS`, `KEDA_MAX_REPLICAS`, `KEDA_MESSAGES_PER_REPLICA`; for phase 2, `EVENT_GRID_DESTINATION_ACCESS` (the value in effect: `enabled` in phase 1) and `PRIVATE_ENDPOINT_IPS` (JSON: private endpoint name → IP address; `{}` in phase 1).
