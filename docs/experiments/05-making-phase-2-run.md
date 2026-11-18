# 05 — Making phase 2 run

**Date:** 2026-11-18 · **Answers:** Q1, Q11 · **Versions:** [00](00-environment.md)

## Goal

Switch the running phase 1 environment to private networking (`PRIVATE_NETWORKING=true`), deploy and test from inside the virtual network, and record every change it needed, with its cause.

## Setup

Phase 1 as in [04](04-scale-to-zero-host-id-probes.md), plus private access on demand ([DESIGN](../DESIGN.md#private-access)): a jumpbox, a Bastion session opened with `infra/scripts/bastion-up.sh 6`, and the reaper. `EVENT_GRID_DESTINATION_ACCESS=enabled` for this first run, so that Event Grid's delivery is not restricted yet. Two applies: the private-access resources with phase 1 settings, then phase 2.

## Steps and results

| # | What happened | Cause | Change |
|---|---|---|---|
| 1 | Creating the jumpbox subnet's network security group association failed: "an association … already exists" | the test tenant's policy attaches a network security group of its own (`<vnet>-<subnet>-nsg-<region>`, no rules) to every subnet that has none; the phase 2 subnets had existed without one since phase 1 | the policy's group detached and deleted just before the apply; the apply then created the association |
| 2 | After the phase 2 apply, the `private-endpoints` subnet had the policy's group again, and ours had no subnet | the two groups were created at 19:11 UTC, their associations later in the same apply; at 19:13 the policy attached groups of its own to both subnets, and on `private-endpoints` its association came after ours | ours attached again with `az network vnet subnet update --nsg`, the policy's groups deleted. No effect on traffic meanwhile: the subnet's private endpoint network policies are off, so its rules don't filter the endpoints |
| 3 | `azd provision --preview` stopped: "User … does not exist in MSAL token cache" | concurrent token requests to the Azure CLI during the plan, as in [01](01-making-phase-1-run.md) | plan and apply with Terraform directly, `-parallelism=2`, on azd's rendered variables |
| 4 | — | the apply took 21 minutes: 40 resources added (15 private endpoints, Service Bus Premium replacing Standard under the same name), 6 changed, 6 destroyed. Both nodes were new afterwards; the pods came back on their own | none |
| 5 | From the jumpbox, without redeploying, one blob per app went through: polling 11.9 s, Storage queue 43.2 s (the queue trigger's backoff after a quiet period, as in [02](02-phase-1-scenarios.md)), Service Bus 5.0 s | the apps reach the host and upload accounts and the new Service Bus namespace through their private endpoints; names resolve through the private DNS zones linked to the virtual network | none |
| 6 | `azd deploy` from the jumpbox: the remote build was refused, "client with IP … is not allowed access" | the registry's public access is off. `networkRuleBypassAllowedForTasks` lets tasks that authenticate with the registry's system-assigned identity through; azd's remote build is a quick run that signs in another way ([network bypass policy for tasks](https://learn.microsoft.com/azure/container-registry/manage-network-bypass-policy-for-tasks)) | images built on the jumpbox: Docker installed there, `remoteBuild: false` in the jumpbox's copy of `azure.yaml`; the push goes through the registry's private endpoint. Deploys took 110, 83 and 73 s |
| 7 | — | the jumpbox needed more than the block's tools (Azure CLI, azd, kubectl, kubelogin): the .NET 10 SDK and make for the repository's commands, Docker for the builds, and one device-code sign-in (`azd config set auth.useAzCliAuth true` so that azd uses it) | installed by hand, about 5 minutes |

## Conclusion

- **Private networking works without code changes (Q1):** the three apps kept processing blobs through the private endpoints across the switch, including through the Service Bus namespace replaced by a Premium one under the same name; the API server answered from the jumpbox only.
- **Operations (Q11):** in phase 2 everything runs from the jumpbox: `kubectl`, the scenarios (the host accounts and the API server are private) and the deploys. azd's remote build doesn't reach a registry whose public access is off; building on a machine inside the virtual network does. A dedicated ACR agent pool in the virtual network is the other route, not tested here.
- **Tenant policies:** where a policy attaches network security groups to subnets that have none, create each subnet's group association in the same apply as the subnet, and check the associations after every apply.
