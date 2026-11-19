# 08 — Costs

**Date:** 2026-11-19 · **Answers:** Q13, Q1 · **Versions:** [00](00-environment.md)

## Goal

Estimate what each way of triggering costs per month, and what the spike's environment costs per hour, from Azure's retail prices.

## Setup

[`scripts/cost-estimate.py`](../../scripts/cost-estimate.py) holds the prices (EUR, francecentral, pay-as-you-go, read on 2026-11-19 from the Azure Retail Prices API) and the usage model, and prints the tables below (`python3 scripts/cost-estimate.py`). It counts what differs between the three ways of triggering:

- **Polling Blob trigger:** a container listing every 10 s (one page: a container of more than 5,000 blobs needs more calls per scan), a receipt written per blob, and its internal queue (put, get, delete).
- **Storage queue:** an Event Grid operation per blob (the first 100,000 a month are free), put, get and delete per message, and the idle queue's polling (once a minute by default, every 2 s with the tuning of [03](03-queue-polling-interval.md)).
- **Service Bus:** an Event Grid operation per blob, and the namespace (Standard: 13 million operations a month included; Premium, which private endpoints need: one messaging unit, operations included).

Not counted: reading the blob and writing the processing record (the same for every option), storage capacity, logs and telemetry (usage-based), discounts and taxes.

## Results

### Each trigger's own cost per month

| Trigger, network | 10,000 blobs | 1,000,000 blobs | 10,000,000 blobs |
|---|---|---|---|
| Polling Blob trigger, public or private | €1.46 | €7.77 | €65.19 |
| Storage queue, default polling | €0.03 | €1.58 | €16.15 |
| Storage queue, `maxPollingInterval` 2 s | €0.48 | €2.04 | €16.61 |
| Service Bus Standard, public | €8.98 | €9.46 | €26.52 |
| Service Bus Premium (1 unit), private | €607.80 | €608.28 | €613.13 |

### Shared by every option

| Shared item | Cost |
|---|---|
| Two D2als_v7 nodes (all options, both phases) | €123.66 a month |
| Private endpoints, 5 per app (private) | €32.85 a month |
| Registry Premium instead of Basic (private) | €40.96 a month |
| Bastion's two static public IPs (private) | €6.57 a month |
| One working hour: Bastion Standard, NAT Gateway, jumpbox (private) | €0.39 |

### The spike's environment

| The spike's environment | Per hour | Per day |
|---|---|---|
| Phase 1 | €0.19 | €4.51 |
| Phase 2, no Bastion session | €1.22 | €29.22 |

Phase 1: the nodes, Service Bus Standard and the registry Basic. Phase 2: Service Bus Premium, the registry Premium, the 16 private endpoints and the Bastion's addresses, with the nodes. Storage, telemetry and the reaper add a few cents a day at the spike's volumes. Multiply by the hours each phase ran for the spike's total.

## Conclusion

- **Q13, public endpoints:** each trigger's own cost stays under €30 a month up to 10 million blobs; the Storage queue is the cheapest (under €17), Service Bus Standard has a €9 base, and the polling trigger grows with the receipts it writes (€65 at 10 million).
- **Q13, private networking:** Service Bus needs the Premium tier for private endpoints: about €608 a month for one messaging unit, which outweighs every other difference. The Storage queue and the polling trigger keep their public-endpoint costs; private endpoints (about €33 a month per app) and the registry Premium (€41) are the same for all.
- **For Q1:** with private networking, the Storage queue with a lower `maxPollingInterval` costs about €2 a month at a million blobs, for a median latency of 1.5 to 2.7 s against Service Bus's 1.1 to 1.8 s (both measured in [03](03-queue-polling-interval.md); [06](06-phase-2-scenarios.md) showed no effect of the private network); Service Bus costs about €600 a month more.
- These are list-price estimates from a usage model; Cost Management wasn't read for the spike's days.
