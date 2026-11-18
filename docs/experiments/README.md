# Experiments

Numbered in the order they run; never renumbered. Copy [TEMPLATE.md](TEMPLATE.md) to `NN-<slug>.md`.

| # | Experiment | Questions | Result |
|---|---|---|---|
| 00 | [Environment](00-environment.md) | — | phase 1 ready, 2026-11-18 |
| 01 | [Making phase 1 run](01-making-phase-1-run.md) | Q2, Q3, Q4, Q8, Q10 | ten changes, each with its cause; Workload Identity works for the host and the three triggers |
| 02 | [Phase 1 scenarios](02-phase-1-scenarios.md) | Q3, Q4, Q5, Q7, Q9, Q10, Q12 | Service Bus 1.6 s, polling 5.4 s, Storage queue 12.7 s (median, 20 blobs); exactly one processing per blob in every failure scenario; scale-out bounded by node capacity |
| 03 | [Storage queue polling interval](03-queue-polling-interval.md) | Q9 | with `maxPollingInterval` 2 s, the Storage queue's median drops from 12.7 s to 1.5–2.7 s |
| 04 | [Scale to zero, no explicit host ID, probes at startup](04-scale-to-zero-host-id-probes.md) | Q3, Q7, Q10 | from zero, a blob processed in 23 s; without a host ID, every new pod reprocesses the container; the ping answers only once the host has started |
| 05 | [Making phase 2 run](05-making-phase-2-run.md) | Q1, Q11 | the apps work through private endpoints without code changes; deploys build on the jumpbox (azd's remote build is refused by the private registry); a tenant policy's network security groups to remove before each apply |
