#!/usr/bin/env bash
# Applies the shared namespace policy after azd has deployed the three services.
# The services create the namespace; this step installs its common egress policy.
# kubectl acts on this environment's cluster (scripts/kubeconfig.sh), not on the default kubeconfig's context.
set -euo pipefail

# shellcheck source=scripts/kubeconfig.sh
source scripts/kubeconfig.sh
kubectl apply -f k8s/namespace.yaml -f k8s/network-policy.yaml
