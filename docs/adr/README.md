# Architecture decision records

An ADR records one decision that is hard to reverse once code, infrastructure or data depend on it: its context, the decision, its consequences (good and bad), the alternatives and the evidence. Decisions that are cheap to change (a setting, a name, a default) live in [DESIGN.md](../DESIGN.md) instead.

These are **drafts** (status *Proposed*): the spike's experiments confirm or change them. Every factual claim in the Evidence section is either:

- **documented**: with a link to Microsoft Learn or to the product's GitHub repository, or
- **to verify**: with the [question](../QUESTIONS.md) whose experiments will answer it.

When an experiment answers a question, update the ADRs that cite it: move the claim to *Observed* with a link to the experiment, then set the status to *Accepted*, or to *Superseded by ADR-NNNN* with a new ADR.

## Format

`ADR-NNNN-<slug>.md`, numbered in the order the decisions are recorded, never renumbered. Sections: Status, Date, Context, Decision, Consequences, Alternatives considered, Evidence.

## Index

| ADR | Decision | Status | Questions |
|---|---|---|---|
| [0001](ADR-0001-three-independent-function-apps.md) | Three independent Function apps with three unique Functions host IDs | Proposed | Q2, Q3, Q8 |
| [0002](ADR-0002-replicas-share-one-host-id.md) | Replicas of one Deployment share one explicit host ID | Proposed | Q3, Q4 |
| [0003](ADR-0003-no-event-grid-blob-trigger-source.md) | The Event Grid-based Blob trigger source is not used for the private AKS scenario | Proposed | Q4, Q9 |
| [0004](ADR-0004-storage-queue-lower-cost-broker.md) | Storage queue evaluated as the lower-cost broker | Proposed | Q5, Q7, Q12, Q13 |
| [0005](ADR-0005-service-bus-premium-for-private-endpoints.md) | Service Bus Premium for private endpoints, Standard while the endpoints are public | Proposed | Q6, Q13 |
| [0006](ADR-0006-no-event-grid-namespaces-pull-delivery.md) | Event Grid namespaces with pull delivery are not in this first spike | Proposed | Q1 |
| [0007](ADR-0007-securing-event-grid-delivery.md) | Event Grid delivery to the Storage queue and Service Bus: system-assigned identity, roles, trusted services | Proposed | Q5, Q6, Q8 |
| [0008](ADR-0008-nsgs-do-not-govern-event-grid-delivery.md) | Network security groups cannot govern Event Grid's deliveries | Proposed | Q5, Q6 |
| [0009](ADR-0009-at-least-once-and-idempotency.md) | At-least-once delivery and idempotency | Proposed | Q4, Q12 |
