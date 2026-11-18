#!/usr/bin/env bash
# Scenario 03, large batch and scaling: uploads a batch to the two KEDA-scaled apps (queue-triggered and
# servicebus-triggered) and samples, every interval, each app's replicas, the HPA KEDA created and the queue length,
# until the queue drains and the replicas are back to the minimum. Reports the peak replicas, the time to the peak,
# the time to drain and the time back to the minimum, all counted from the start of the upload.
#
# Informs: Q7 (KEDA with Workload Identity: scale-out and back), Q9 (latency for a batch), Q12 (one processing per
# blob).
# Changes: uploads the batch to accounts 2 and 3 (left in place); KEDA scales the apps out and back on its own.
# Nothing to restore.
#
# Usage: scripts/scenarios/03-large-batch-scale.sh [--count N] [--parallelism N] [--interval SECONDS]
#                                                  [--timeout SECONDS]
#   --count N           blobs per app (default 500)
#   --parallelism N     uploads in flight at once (default 32)
#   --interval SECONDS  time between samples (default 10)
#   --timeout SECONDS   stops sampling after this long, from the start of the upload (default 3600)
#   --help              prints this text
#
# Reading the result: the samples go to standard error as they are taken ("t=<s> <app> ready=<n> desired=<n>
# hpa=<current>/<desired> queue=<messages>"; redirect them with 2>samples.log for the experiment's evidence), then one
# Markdown row per app. Times are in seconds; "n/a" means it did not happen before the timeout. The minimum is
# KEDA_MIN_REPLICAS; KEDA's default cool-down (300 s) and the HPA's scale-down window make "back to minimum" minutes
# after the drain. The exit status is non-zero when a blob has no record or the sampling timed out.
# Needs: as scenario 01, plus the cluster (scripts/kubeconfig.sh) and Reader on the Service Bus namespace.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

count=500
parallelism=32
interval_seconds=10
timeout_seconds=3600
while (($# > 0)); do
  case "$1" in
    --count) count="${2:?--count needs a value}"; shift 2 ;;
    --parallelism) parallelism="${2:?--parallelism needs a value}"; shift 2 ;;
    --interval) interval_seconds="${2:?--interval needs a value}"; shift 2 ;;
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --count "$count"
require_positive_integer --parallelism "$parallelism"
require_positive_integer --interval "$interval_seconds"
require_positive_integer --timeout "$timeout_seconds"

# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/../kubeconfig.sh"

apps=(queue-triggered servicebus-triggered)
start_scenario 03
minimum_replicas="$(azd_value KEDA_MIN_REPLICAS)"
queue_account="$(upload_account queue-triggered)"
resource_group="$(azd_value AZURE_RESOURCE_GROUP)"
service_bus_namespace="$(azd_value SERVICE_BUS_NAMESPACE)"

queue_length() {
  local app="$1"

  if [[ "$app" == queue-triggered ]]; then
    storage_queue_length "$queue_account" blob-events
    return
  fi
  az servicebus queue show \
    --resource-group "$resource_group" \
    --namespace-name "$service_bus_namespace" \
    --name blob-events \
    --query countDetails.activeMessageCount \
    --output tsv
}

# KEDA names the HPA it creates for a ScaledObject keda-hpa-<ScaledObject name>.
hpa_replicas() {
  kubectl get hpa "keda-hpa-$1" --namespace functions \
    --output 'jsonpath={.status.currentReplicas}/{.status.desiredReplicas}'
}

declare -A upload_pids uploads_finished_at peak_replicas peak_at has_seen_messages drained_at minimum_at
upload_started=$SECONDS
for app in "${apps[@]}"; do
  upload_blobs "$app" "$count" "$parallelism" &
  upload_pids["$app"]=$!
  uploads_finished_at["$app"]=""
  peak_replicas["$app"]=0
  peak_at["$app"]="n/a"
  has_seen_messages["$app"]=false
  drained_at["$app"]=""
  minimum_at["$app"]=""
done

# A queue seen empty right after the upload may not have received Event Grid's messages yet: it counts as drained once
# it held messages, or a minute after the upload ended.
is_drained() {
  local app="$1"
  local elapsed="$2"
  local messages="$3"

  if ((messages > 0)) || [[ -z "${uploads_finished_at[$app]}" ]]; then
    return 1
  fi
  if [[ "${has_seen_messages[$app]}" == true ]]; then
    return 0
  fi
  local uploads_ended="${uploads_finished_at[$app]}"
  ((elapsed - uploads_ended >= 60))
}

# Records one sample for the app and updates its peak, drain and back-to-minimum times.
take_sample() {
  local app="$1"
  local elapsed="$2"
  local ready
  local desired
  local messages
  local peak="${peak_replicas[$app]}"

  ready="$(ready_replicas "$app")"
  desired="$(desired_replicas "$app")"
  messages="$(queue_length "$app")"
  messages="${messages:-0}"
  log_step "t=${elapsed} ${app} ready=${ready} desired=${desired} hpa=$(hpa_replicas "$app") queue=${messages}"
  if ((ready > peak)); then
    peak_replicas["$app"]=$ready
    peak_at["$app"]=$elapsed
  fi
  if ((messages > 0)); then
    has_seen_messages["$app"]=true
  fi
  if [[ -z "${uploads_finished_at[$app]}" ]] && ! kill -0 "${upload_pids[$app]}" 2>/dev/null; then
    uploads_finished_at["$app"]=$elapsed
  fi
  if [[ -z "${drained_at[$app]}" ]] && is_drained "$app" "$elapsed" "$messages"; then
    drained_at["$app"]=$elapsed
  fi
  if [[ -n "${drained_at[$app]}" && -z "${minimum_at[$app]}" ]] &&
    ((ready == minimum_replicas && desired == minimum_replicas)); then
    minimum_at["$app"]=$elapsed
  fi
}

has_timed_out=false
while true; do
  elapsed=$((SECONDS - upload_started))
  all_back_to_minimum=true
  for app in "${apps[@]}"; do
    take_sample "$app" "$elapsed"
    [[ -n "${minimum_at[$app]}" ]] || all_back_to_minimum=false
  done
  if [[ "$all_back_to_minimum" == true ]]; then
    break
  fi
  if ((elapsed >= timeout_seconds)); then
    has_timed_out=true
    break
  fi
  sleep "$interval_seconds"
done

for app in "${apps[@]}"; do
  wait "${upload_pids[$app]}"
  wait_until_processed "$app" 300 || log_step "$app: records still missing"
done
if [[ "$has_timed_out" == true ]]; then
  fail_expectation "sampling stopped after ${timeout_seconds}s before every app was back to the minimum"
fi

markdown_row Run App Blobs 'Min replicas' 'Peak replicas' 'Time to peak (s)' 'Time to drain (s)' \
  'Time back to minimum (s)' Records
markdown_separator 9
for app in "${apps[@]}"; do
  markdown_row "$RUN_ID" "$app" "$count" "$minimum_replicas" "${peak_replicas[$app]}" "${peak_at[$app]}" \
    "${drained_at[$app]:-n/a}" "${minimum_at[$app]:-n/a}" "$(check_records "$app")"
done
finish_scenario
