#!/usr/bin/env bash
# Scenario 05, pod restart: uploads a batch to each app, deletes one of the app's processing pods once about a quarter
# of the batch has its processing record, then checks that every blob still ends with exactly one record and reports
# how many invocations were retried.
#
# Informs: Q12 (a pod killed mid-processing: retries, no lost or doubled blob), Q9 (latency with a restart).
# Changes: uploads the batch (left in place) and deletes one pod per app; its Deployment (or KEDA) replaces it, and the
# scenario waits for the Deployment to be complete again.
#
# Usage: scripts/scenarios/05-pod-restart.sh [--app APP] [--count N] [--parallelism N] [--grace-period SECONDS]
#                                            [--timeout SECONDS] [--ingestion-timeout SECONDS]
#   --app APP                    blob-polling, queue-triggered or servicebus-triggered (default: all three, in turn)
#   --count N                    blobs per app (default 200)
#   --parallelism N              uploads in flight at once (default 32)
#   --grace-period SECONDS       passed to kubectl delete pod; 0 kills the pod at once (default: the pod's own)
#   --timeout SECONDS            how long to wait for the records, per app (default 1200)
#   --ingestion-timeout SECONDS  how long to wait for Application Insights, per app (default 600)
#   --help                       prints this text
#
# Reading the result: one Markdown row per app. "Records at delete" is how far the batch had got when the pod was
# deleted. "Retries" counts the extra invocations Application Insights saw for a blob (the deleted pod's unfinished
# work picked up again); "Duplicates" the processings that found the record already there. Expected: "Records"
# N/N and no blob processed twice without being logged as a duplicate. The exit status is non-zero otherwise, or when
# the batch finished before a pod could be deleted (rerun with a larger --count).
# Needs: as scenario 01, plus the cluster (scripts/kubeconfig.sh) with the right to delete pods in "functions".
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

apps=(blob-polling queue-triggered servicebus-triggered)
count=200
parallelism=32
grace_period=""
timeout_seconds=1200
ingestion_timeout_seconds=600
while (($# > 0)); do
  case "$1" in
    --app) require_app "${2:?--app needs a value}"; apps=("$2"); shift 2 ;;
    --count) count="${2:?--count needs a value}"; shift 2 ;;
    --parallelism) parallelism="${2:?--parallelism needs a value}"; shift 2 ;;
    --grace-period) grace_period="${2:?--grace-period needs a value}"; shift 2 ;;
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --ingestion-timeout) ingestion_timeout_seconds="${2:?--ingestion-timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --count "$count"
require_positive_integer --parallelism "$parallelism"
[[ -z "$grace_period" ]] || [[ "$grace_period" =~ ^[0-9]+$ ]] || {
  echo "--grace-period must be a whole number of seconds" >&2
  exit 2
}
require_positive_integer --timeout "$timeout_seconds"
require_positive_integer --ingestion-timeout "$ingestion_timeout_seconds"

# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/../kubeconfig.sh"

start_scenario 05

# Prints the name of one running pod of the app, or nothing.
running_pod() {
  kubectl get pods --namespace functions --selector "app=$1" --field-selector status.phase=Running \
    --output 'jsonpath={.items[0].metadata.name}' 2>/dev/null || true
}

# Waits until a quarter of the batch has its record, then deletes a running pod; prints "<pod>\t<records>", or
# nothing when the batch finished first.
delete_pod_mid_batch() {
  local app="$1"
  local threshold=$(((count + 3) / 4))
  local deadline=$((SECONDS + timeout_seconds))
  local found
  local pod
  local -a grace_option=()

  [[ -z "$grace_period" ]] || grace_option=(--grace-period "$grace_period")
  while ((SECONDS < deadline)); do
    found="$(recent_record_count "$app")"
    pod="$(running_pod "$app")"
    if ((found >= count)); then
      return 0
    fi
    if ((found >= threshold)) && [[ -n "$pod" ]]; then
      kubectl delete pod "$pod" --namespace functions --wait=false "${grace_option[@]}" >&2
      printf '%s\t%s\n' "$pod" "$found"
      return 0
    fi
    sleep 2
  done
}

declare -A deleted_pod records_at_delete
for app in "${apps[@]}"; do
  upload_blobs "$app" "$count" "$parallelism" &
  upload_pid=$!
  IFS=$'\t' read -r pod found_at_delete < <(delete_pod_mid_batch "$app") || true
  wait "$upload_pid"
  if [[ -z "${pod:-}" ]]; then
    fail_expectation "$app: the batch finished (or timed out) before a pod could be deleted"
  fi
  deleted_pod["$app"]="${pod:-none}"
  records_at_delete["$app"]="n/a"
  [[ -z "${found_at_delete:-}" ]] || records_at_delete["$app"]="$found_at_delete/$count"
  log_step "$app: deleted pod ${deleted_pod[$app]} at ${records_at_delete[$app]} records"
  wait_until_processed "$app" "$timeout_seconds" || log_step "$app: records still missing after ${timeout_seconds}s"
  wait_for_rollout "$app"
  pod=""
  found_at_delete=""
done
for app in "${apps[@]}"; do
  wait_for_processing_rows "$app" "$ingestion_timeout_seconds" ||
    log_step "$app: not every blob is in Application Insights after ${ingestion_timeout_seconds}s"
done

markdown_row Run App Blobs 'Deleted pod' 'Records at delete' 'Max latency (ms)' Records Retries Duplicates
markdown_separator 9
for app in "${apps[@]}"; do
  rows_file="$(processing_rows_file "$app")"
  IFS=$'\t' read -r _ _ _ maximum _ < <(latency_distribution "$rows_file")
  check_single_processing "$app"
  markdown_row "$RUN_ID" "$app" "$count" "\`${deleted_pod[$app]}\`" "${records_at_delete[$app]}" "$maximum" \
    "$(check_records "$app")" "$(retry_count "$rows_file")" "$(column_sum "$rows_file" 5)"
done
finish_scenario
