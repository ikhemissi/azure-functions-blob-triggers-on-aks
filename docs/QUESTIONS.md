# Questions

Q1 is the spike's question; Q2 to Q13 are what it takes to answer it. [docs/DESIGN.md](DESIGN.md) is the setup they are asked about. Each question is answered in phase 1 (public endpoints) and again in phase 2 (private) where networking can change the answer.

| # | Question | Experiments | Status |
|---|---|---|---|
| Q1 | Which way of triggering Azure Functions on AKS after a blob upload (the polling Blob trigger, Event Grid to a Storage queue, or Event Grid to Service Bus) works best with private networking, identity-only access and KEDA scaling, and at what latency, cost and operational effort? | — | open |
| Q2 | Does the Functions host in a container on AKS use Workload Identity for its own storage and for the three triggers (`__credential=workloadidentity`), with no keys or connection strings? | — | open |
| Q3 | Host IDs: do the replicas of one app share an explicit host ID (receipts, leases, singleton scan), what happens without one, and what happens to existing blobs when the host ID or the host storage changes? | — | open |
| Q4 | The polling Blob trigger: latency for one blob and for batches, where its receipts and scan state live, behaviour with 2 replicas, and what it does without permission to turn on the account's analytics logs? | — | open |
| Q5 | Event Grid to a Storage queue with the system topic's identity: does delivery work with the account's public access (a) on, (b) limited to selected networks with trusted services, (c) disabled? Which message encoding does the queue trigger need? | — | open |
| Q6 | Event Grid to a Service Bus Premium queue with the system topic's identity: does delivery work with public access (a) on, (b) limited with trusted services, (c) disabled? | — | open |
| Q7 | KEDA with Workload Identity: do apps 2 and 3 scale out under a batch and back to the minimum, and to zero when allowed, and how fast? | — | open |
| Q8 | The least roles each identity needs: the apps', KEDA's (queue length, Service Bus message count) and Event Grid's (delivery, dead-letter). | — | open |
| Q9 | End-to-end latency (upload to processed) per trigger, for one blob, concurrent blobs and a batch, with public endpoints and then private ones. | — | open |
| Q10 | Probes: is the host's anonymous `/admin/host/ping` usable for liveness and readiness, including while the host starts? | — | open |
| Q11 | Phase 2 operations: deploying to the private cluster through a Bastion jumpbox, and building images with ACR Tasks into a private registry. | — | open |
| Q12 | At-least-once delivery: duplicates (Event Grid redelivery, pod restart during processing, rolling deployment, a dependency briefly unavailable), poison and dead-letter handling; does the idempotency record keep exactly one processing per blob? | — | open |
| Q13 | Cost: per month for each option, and for the spike's days. | — | open |

Status: `open`, `answered`, `partly answered`, `unanswered` (with what blocked it).
