# Retest plan

What to run again when a product, an SDK or a policy changes, so that the findings stay true.

| Experiment | Retest when | How | Last run |
|---|---|---|---|
| [01](experiments/01-making-phase-1-run.md), the blob extension pin | `Microsoft.Azure.Functions.Worker.Extensions.Storage.Blobs` brings WebJobs blob extension 5.3.10 or later | remove `src/BlobExtensionVersion` and its reference, check the version in `.azurefunctions/function.deps.json`, run scenarios 1, 2 and 10 | 2026-11-18 |
| [01](experiments/01-making-phase-1-run.md), the trace-based log sampler | a new Azure Monitor OpenTelemetry exporter, or the Functions host passing sampled traces | remove `EnableTraceBasedLogsSampler = false` from `FunctionServices`, check that invocation logs reach Application Insights | 2026-11-18 |
| [01](experiments/01-making-phase-1-run.md), `POD_NAMESPACE` | a new Functions host image | add `POD_NAMESPACE` to blob-polling's Deployment, check whether its listener starts | 2026-11-18 |
| [03](experiments/03-queue-polling-interval.md), queue polling | a new Storage queues extension | scenarios 1 and 2 with and without `maxPollingInterval` 2 s | 2026-11-18 |
| [04](experiments/04-scale-to-zero-host-id-probes.md), scale to zero, host IDs, probes | a new KEDA or Functions host version | the three steps of 04 | 2026-11-18 |
| [05](experiments/05-making-phase-2-run.md), building for a private registry | azd or ACR Tasks changes for network-restricted registries | `azd deploy` with `remoteBuild: true` from the jumpbox | 2026-11-18 |
| [06](experiments/06-phase-2-scenarios.md), the scenarios | an AKS, KEDA, Functions host or SDK upgrade | scenarios 1 to 10 with the arguments listed in 06's setup | 2026-11-18 |
| [07](experiments/07-event-grid-destination-access.md), Event Grid destination access | changes to Event Grid delivery, Storage or Service Bus network rules | each `EVENT_GRID_DESTINATION_ACCESS` value, scenarios 1, 2, 4 and 8, and an upload from outside | 2026-11-19 |
| [08](experiments/08-costs.md), costs | prices change, or every quarter | update `PRICES` in `scripts/cost-estimate.py` from the Retail Prices API, run it | 2026-11-19 |
