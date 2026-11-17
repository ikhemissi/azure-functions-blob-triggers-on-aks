#!/usr/bin/env bash
# Prints recent logs from the selected Function app's pods.
# Reads the current Kubernetes context in the design's functions namespace.
set -euo pipefail

[[ $# -eq 1 ]] || {
  echo "usage: $0 <blob-polling|queue-triggered|servicebus-triggered>" >&2
  exit 2
}
case "$1" in
  blob-polling|queue-triggered|servicebus-triggered) ;;
  *)
    echo "unknown app: $1" >&2
    exit 2
    ;;
esac

kubectl logs \
  --namespace functions \
  --selector "app=$1" \
  --all-containers=true \
  --prefix=true \
  --since=15m \
  --tail=100 \
  --max-log-requests=10
