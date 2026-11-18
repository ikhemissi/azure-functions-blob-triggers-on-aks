#!/usr/bin/env bash
# Shows ready replicas for the three Function Deployments and KEDA-created HPAs.
# Uses this environment's cluster (scripts/kubeconfig.sh) and the design's functions namespace.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/kubeconfig.sh"

kubectl get deployments \
  blob-polling queue-triggered servicebus-triggered \
  --namespace functions \
  --output 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas'
kubectl get hpa --namespace functions
