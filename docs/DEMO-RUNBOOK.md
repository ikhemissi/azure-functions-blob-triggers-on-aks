# Demo runbook

A step-by-step script to show the results, written so that someone else can run it. It shows phase 2 (private networking); in phase 1 the same commands run from a laptop.

## Before the demo

- [ ] 15 minutes before: `infra/scripts/bastion-up.sh 2` (the Bastion host takes about 10 minutes), then `infra/scripts/bastion-tunnel.sh` in a terminal of its own, and `ssh -F .azure/<environment>/ssh/config jumpbox` (renew with the tunnel script after an hour).
- [ ] On the jumpbox: `cd azure-functions-blob-triggers-on-aks && export KUBECONFIG=$PWD/.azure/<environment>/kubeconfig`, `az account show` (sign in with `az login --use-device-code` if asked), `kubectl -n functions get pods` shows the four pods ready.
- [ ] Browser tabs: the README's diagram and key findings, experiment 08's tables, Application Insights (Logs).
- [ ] One blob per app a few minutes before (`bash scripts/scenarios/01-one-blob.sh`), so the Storage queue isn't in its idle backoff.

## Steps

| # | Do | Show | Say |
|---|---|---|---|
| 1 | Open the README | the diagram | Three ways to trigger the same function after a blob upload, side by side in one cluster, identities only, everything private. |
| 2 | `kubectl -n functions get deploy,scaledobject` | three apps, two ScaledObjects | The polling trigger runs fixed replicas; the two event-driven apps scale with KEDA, down to zero if allowed. |
| 3 | `bash scripts/scenarios/02-concurrent-blobs.sh` | the latency table | Service Bus pushes (about 1 to 2 s); the Storage queue follows when its polling interval is lowered; the polling trigger waits for its 10 s container scan. |
| 4 | `bash scripts/scenarios/04-duplicate-delivery.sh` | "Duplicates logged 1", "Records 1/1" | Delivery is at least once: the same event twice gives one record. |
| 5 | On the laptop: `az storage blob upload --account-name <upload account 2> --container-name uploads --name probe.txt --file <file> --auth-mode login` | refused by the network rules | Nothing outside the network gets in, yet Event Grid delivered in step 3: it is a trusted service with a managed identity. |
| 6 | `python3 scripts/cost-estimate.py` | the tables | With private endpoints, Service Bus needs Premium, about €608 a month; the Storage queue's own cost is a few euros. |

## If something fails

- A scenario times out: show the recorded tables in [experiment 06](experiments/06-phase-2-scenarios.md) and [07](experiments/07-event-grid-destination-access.md); `kubectl -n functions logs deploy/<app>` for the cause.
- The jumpbox is unreachable: the session may have ended (the reaper deletes the host at its time); `infra/scripts/bastion-up.sh 1` again, or show the README's key findings and the experiments.
- The first blob on the Storage queue takes up to a minute: the trigger's idle backoff (experiment 03), not a failure.
