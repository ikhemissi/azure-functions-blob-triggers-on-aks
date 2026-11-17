# Azure Functions on AKS: three ways to trigger on a blob upload

**Question:** Which way of triggering Azure Functions on AKS after a blob upload (the polling Blob trigger, Event Grid to a Storage queue, or Event Grid to Service Bus) works best with private networking, identity-only access and KEDA scaling, and at what latency, cost and operational effort?

**Time box:** 3 phases, stop and report after each · **Status:** in progress

## The setup

TODO: what runs where, in a few sentences, and with which identities; then the diagram of the components (a
`flowchart`, one arrow per call, labelled with the identity it uses).

```mermaid
flowchart LR
    user(["User"]) --> client["TODO: client or agent"]
    client -->|"TODO: identity"| service["TODO: what the spike examines"]
    service --> dependency["TODO: what it calls"]
```

## Key findings

TODO: once the first experiments are done, one line per question (a table), and a diagram of the most important
behaviour when it helps (a `sequenceDiagram`).

The answers to every question, with the evidence: **[docs/FINDINGS.md](docs/FINDINGS.md)**.

## Documents

| Document | Content |
|---|---|
| [Questions](docs/QUESTIONS.md) | What the spike must answer, and the status of each question |
| [Experiments](docs/experiments/README.md) | One file per experiment, numbered |
| [Findings](docs/FINDINGS.md) | The answers, with links to the evidence |
| [Retest plan](docs/RETEST-PLAN.md) | What to run again when a product changes |
| [Demo runbook](docs/DEMO-RUNBOOK.md) | How to show the results |

## Environment

The infrastructure is one Terraform root (`infra/`), one file per part, built from the modules in `infra/modules/`. azd runs the steps of `infra/hooks/<event>/` around it (state backend before, configuration after, a clean teardown).

```bash
az login && azd auth login
azd env new aksfunc-dev --location francecentral
azd env set RESOURCE_TAGS "key=value,key=value"   # tags your tenant's policies require, if any
azd hooks run preprovision                        # remote state backend: once before the first preview
azd provision --preview                           # read the plan
azd up                                            # provision, then deploy the services
```

Later changes: `azd provision --preview`, read the plan, then `azd provision`.

Tear it down when the spike ends: `azd down --purge`.

## Build and test locally

```bash
dotnet test BlobTriggers.slnx                     # the apps' unit tests
terraform -chdir=infra fmt -check -recursive      # then terraform test in each infra/modules/<module>
```

The design every part follows: [docs/DESIGN.md](docs/DESIGN.md).
