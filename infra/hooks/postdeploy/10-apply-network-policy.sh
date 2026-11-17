#!/usr/bin/env bash
# Applies the shared namespace policy after azd has deployed the three services.
# The services create the namespace; this step installs its common egress policy.
set -euo pipefail

kubectl apply -f k8s/namespace.yaml -f k8s/network-policy.yaml
