#!/usr/bin/env bash
# Scenario 09, historical blobs: scales blob-polling to zero replicas, uploads blobs while no host runs, scales it back,
# and reports how long the polling trigger takes to find and process blobs that were written while it was down (its
# scan of the container, compared against its receipts).
#
# Informs: Q4 (the polling trigger's scan and receipts; latency for blobs written while it was down), Q3 (the
# receipts kept by the shared host ID across the restart).
# Changes: scales the Deployment blob-polling to 0, then back to its replica count before the run
# (BLOB_POLLING_REPLICAS, default 2), also on exit, on failure. Uploads the blobs (left in place).
#
# Usage: scripts/scenarios/09-historical-blobs.sh [--count N] [--offline SECONDS] [--timeout SECONDS]
#                                                 [--ingestion-timeout SECONDS]
#   --count N                    blobs uploaded while blob-polling is at zero (default 20)
#   --offline SECONDS            how long blob-polling stays at zero, from the first upload (default 60)
#   --timeout SECONDS            how long to wait for the records after the scale-up (default 1800)
#   --ingestion-timeout SECONDS  how long to wait for Application Insights (default 600)
#   --help                       prints this text
#
# Reading the result: one Markdown row. "Records while at zero" must be 0. "Pods ready" is the time from the scale-up
# until every replica was ready; "All processed" the time from the scale-up until every blob had its record; "Max
# latency" is upload to processed for the slowest blob (it includes the time offline). Expected: "Records" N/N and no
# blob processed twice; the exit status is non-zero otherwise.
# Needs: as scenario 01, plus the cluster (scripts/kubeconfig.sh) with the right to scale Deployments in "functions".
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

count=20
offline_seconds=60
timeout_seconds=1800
ingestion_timeout_seconds=600
while (($# > 0)); do
  case "$1" in
    --count) count="${2:?--count needs a value}"; shift 2 ;;
    --offline) offline_seconds="${2:?--offline needs a value}"; shift 2 ;;
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --ingestion-timeout) ingestion_timeout_seconds="${2:?--ingestion-timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --count "$count"
require_positive_integer --offline "$offline_seconds"
require_positive_integer --timeout "$timeout_seconds"
require_positive_integer --ingestion-timeout "$ingestion_timeout_seconds"

# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/../kubeconfig.sh"

app=blob-polling
start_scenario 09
replicas="$(kubectl get deployment "$app" --namespace functions --output 'jsonpath={.spec.replicas}')"

scale_back_and_clean_up() {
  kubectl scale deployment "$app" --namespace functions --replicas "$replicas" >&2 || true
  remove_work_dir
}
trap scale_back_and_clean_up EXIT

log_step "$app: scaling to 0"
kubectl scale deployment "$app" --namespace functions --replicas 0 >&2
wait_for_no_pods "$app"
offline_started=$SECONDS
upload_blobs "$app" "$count" "$count"
remaining=$((offline_seconds - (SECONDS - offline_started)))
((remaining <= 0)) || sleep "$remaining"
records_while_at_zero="$(found_record_count "$app")"
if ((records_while_at_zero > 0)); then
  fail_expectation "$app: $records_while_at_zero blob(s) processed while no replica ran (is another host polling?)"
fi

log_step "$app: scaling back to $replicas"
scaled_up_at=$SECONDS
kubectl scale deployment "$app" --namespace functions --replicas "$replicas" >&2
wait_for_rollout "$app"
pods_ready_after=$((SECONDS - scaled_up_at))
all_processed_after="n/a"
if wait_until_processed "$app" "$timeout_seconds"; then
  all_processed_after=$((SECONDS - scaled_up_at))
fi
wait_for_processing_rows "$app" "$ingestion_timeout_seconds" ||
  log_step "$app: not every blob is in Application Insights after ${ingestion_timeout_seconds}s"

rows_file="$(processing_rows_file "$app")"
IFS=$'\t' read -r _ _ _ maximum _ < <(latency_distribution "$rows_file")
check_single_processing "$app"
markdown_row Run App Blobs 'Offline (s)' 'Records while at zero' 'Pods ready (s)' 'All processed (s)' \
  'Max latency (ms)' Records Duplicates
markdown_separator 10
markdown_row "$RUN_ID" "$app" "$count" "$offline_seconds" "$records_while_at_zero" "$pods_ready_after" \
  "$all_processed_after" "$maximum" "$(check_records "$app")" "$(column_sum "$rows_file" 5)"
finish_scenario
