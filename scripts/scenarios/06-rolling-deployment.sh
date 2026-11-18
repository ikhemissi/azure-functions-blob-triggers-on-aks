#!/usr/bin/env bash
# Scenario 06, rolling deployment: uploads a batch to every app and, while it is being processed, restarts each
# Deployment (kubectl rollout restart, the same rolling update a new image triggers), then checks that every blob
# ends with exactly one record and reports how many invocations were retried.
#
# Informs: Q12 (a rolling update mid-batch: retries, no lost or doubled blob), Q3 (one shared host ID across a rollout).
# Changes: uploads the batch (left in place) and restarts each Deployment (new pods, same spec, a
# kubectl.kubernetes.io/restartedAt annotation added to the pod template). Waits for each rollout to complete.
#
# Usage: scripts/scenarios/06-rolling-deployment.sh [--count N] [--parallelism N] [--restart-after SECONDS] [--timeout SECONDS]
#                                                   [--ingestion-timeout SECONDS]
#   --count N                    blobs per app (default 500)
#   --parallelism N              uploads in flight at once (default 32)
#   --restart-after SECONDS      restarts each Deployment this long after its upload starts (default 20)
#   --timeout SECONDS            how long to wait for the records, per app (default 1200)
#   --ingestion-timeout SECONDS  how long to wait for Application Insights, per app (default 600)
#   --help                       prints this text
#
# Reading the result: one Markdown row per app. "Records at restart" is how far the batch had got when the rollout
# started (N/N means the batch was done before the restart: rerun with a larger --count). "Retries" counts the extra
# invocations Application Insights saw for a blob, "Duplicates" the processings that found the record already there.
# Expected: "Records" N/N and no blob processed twice without being logged as a duplicate; the exit status is non-zero
# otherwise.
# Needs: as scenario 01, plus the cluster (scripts/kubeconfig.sh) with the right to patch Deployments in "functions".
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

count=500
parallelism=32
restart_after_seconds=20
timeout_seconds=1200
ingestion_timeout_seconds=600
while (($# > 0)); do
  case "$1" in
    --count) count="${2:?--count needs a value}"; shift 2 ;;
    --parallelism) parallelism="${2:?--parallelism needs a value}"; shift 2 ;;
    --restart-after) restart_after_seconds="${2:?--restart-after needs a value}"; shift 2 ;;
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --ingestion-timeout) ingestion_timeout_seconds="${2:?--ingestion-timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --count "$count"
require_positive_integer --parallelism "$parallelism"
require_positive_integer --timeout "$timeout_seconds"
require_positive_integer --ingestion-timeout "$ingestion_timeout_seconds"

# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/../kubeconfig.sh"

apps=(blob-polling queue-triggered servicebus-triggered)
start_scenario 06

# Each app's Deployment restarts while its own batch is still being uploaded and processed: restarting after all the
# uploads let the apps finish first, so the restart overlapped no processing.
declare -A records_at_restart
for app in "${apps[@]}"; do
  upload_blobs "$app" "$count" "$parallelism" &
  sleep "$restart_after_seconds"
  records_at_restart["$app"]="$(recent_record_count "$app")/$count"
  log_step "$app: restarting the Deployment at ${records_at_restart[$app]} records"
  kubectl rollout restart deployment "$app" --namespace functions >&2
  wait
done
for app in "${apps[@]}"; do
  wait_for_rollout "$app"
done
for app in "${apps[@]}"; do
  wait_until_processed "$app" "$timeout_seconds" || log_step "$app: records still missing after ${timeout_seconds}s"
done
for app in "${apps[@]}"; do
  wait_for_processing_rows "$app" "$ingestion_timeout_seconds" ||
    log_step "$app: not every blob is in Application Insights after ${ingestion_timeout_seconds}s"
done

markdown_row Run App Blobs 'Records at restart' 'Max latency (ms)' Records Retries Duplicates
markdown_separator 8
for app in "${apps[@]}"; do
  rows_file="$(processing_rows_file "$app")"
  IFS=$'\t' read -r _ _ _ maximum _ < <(latency_distribution "$rows_file")
  check_single_processing "$app"
  markdown_row "$RUN_ID" "$app" "$count" "${records_at_restart[$app]}" "$maximum" "$(check_records "$app")" \
    "$(retry_count "$rows_file")" "$(column_sum "$rows_file" 5)"
done
finish_scenario
