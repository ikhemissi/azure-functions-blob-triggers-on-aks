# 00 — Environment

**Date:** 2026-11-18 · **Versions:** see the table

## Goal

Record the environment every experiment runs in, so that results can be compared and retested.

## Setup

| Item | Value |
|---|---|
| Region | francecentral |
| Phase | 1: public endpoints with Entra authentication only, AKS nodes in the spike's own virtual network, API server limited to the deployer's IP |
| AKS | Kubernetes 1.37.1, Free tier, 2 × Standard_D2als_v7 (Ubuntu 24.04.5, containerd 2.3.7), Azure CNI Overlay with Cilium, API Server VNet Integration, Workload Identity, KEDA add-on 2.20.2 |
| Functions | host 4.1055.300.9 (`mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated10.0`), .NET 10.0.15, worker 2.52.0, Worker SDK 2.1.0; extensions: Storage.Blobs 6.8.2 (host side pinned to WebJobs 5.3.10, see [01](01-making-phase-1-run.md)), Storage.Queues 5.5.5, ServiceBus 5.24.0; Azure Monitor exporter 1.10.0 |
| Brokers | Storage queue (StorageV2, shared keys off), Service Bus Standard (local auth off), Event Grid system topics with system-assigned identities |
| Identities | one user-assigned identity per app, federated with its service account and with KEDA's operator; the deployer's Entra user for the tests |
| Tools | Terraform 1.15.8, azd 1.37.3, Azure CLI 2.88.0, kubectl with kubelogin |

## Result

Environment provisioned on 2026-11-17 and the apps deployed on 2026-11-18, after the changes of [01](01-making-phase-1-run.md). The integration test (`scripts/integration-test.sh`) passes: one blob per app, exactly one processing record each.
