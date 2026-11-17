#!/usr/bin/env bash
# Shows ready replicas for the three Function Deployments and KEDA-created HPAs.
# Uses the current Kubernetes context and the design's functions namespace.
set -euo pipefail

kubectl get deployments \
  blob-polling queue-triggered servicebus-triggered \
  --namespace functions \
  --output 'custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas'
kubectl get hpa --namespace functions
