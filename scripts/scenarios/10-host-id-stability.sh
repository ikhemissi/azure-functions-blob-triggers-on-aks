#!/usr/bin/env bash
# Scenario 10, host ID stability: records each app's processing-record count and host ID, restarts every Deployment
# (new pods), waits, and checks that no blob was processed again: the polling trigger keeps its receipts because the
# replicas share an explicit host ID (AzureFunctionsWebHost__hostid) that does not change with the pods.
#
# Informs: Q3 (an explicit, stable host ID; receipts kept across restarts), Q4 (the polling trigger's receipts).
# Changes: restarts the three Deployments (kubectl rollout restart: new pods, same spec) and waits for the rollouts.
# Run it with no upload in progress: any processing during the wait counts as a failure.
#
# Usage: scripts/scenarios/10-host-id-stability.sh [--wait SECONDS]
#   --wait SECONDS  how long to watch after the rollouts, for the polling trigger's scan to run (default 600)
#   --help          prints this text
#
# Reading the result: one Markdown row per app. "Records before/after" is the count of the app's whole partition of the
# processed table; "Host ID before/after" comes from the Deployment. "Processings since restart" counts the
# "Blob processing finished" log lines in Application Insights since the restart (of which "duplicate=true" ones in
# brackets: a re-scan that lost its receipts shows up there). Expected: records unchanged, the same non-empty host ID,
# and 0 processings; the exit status is non-zero otherwise. Logs reach Application Insights a few minutes late: keep
# --wait at several minutes.
# Needs: as scenario 01, plus the cluster (scripts/kubeconfig.sh) with the right to patch Deployments in "functions".
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

wait_seconds=600
while (($# > 0)); do
  case "$1" in
    --wait) wait_seconds="${2:?--wait needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --wait "$wait_seconds"

# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/../kubeconfig.sh"

apps=(blob-polling queue-triggered servicebus-triggered)
start_scenario 10

host_id() {
  kubectl get deployment "$1" --namespace functions \
    --output 'jsonpath={.spec.template.spec.containers[0].env[?(@.name=="AzureFunctionsWebHost__hostid")].value}'
}

# Prints "<finished processings>\t<of which duplicates>" for the app since the time.
processings_since() {
  local app="$1"
  local since="$2"
  local query
  local rows

  query=$(
    cat <<KUSTO
traces
| where timestamp >= datetime(${since})
| where tostring(customDimensions["app"]) == "${app}"
| where isnotnull(todouble(customDimensions["latencyMs"]))
| summarize processings = count(),
            duplicates = countif(tolower(tostring(customDimensions["duplicate"])) == "true")
KUSTO
  )
  rows="$(app_insights_rows "$query")"
  [[ -n "$rows" ]] || rows=$'0\t0'
  printf '%s\n' "$rows"
}

declare -A records_before host_id_before
for app in "${apps[@]}"; do
  records_before["$app"]="$(total_record_count "$app")"
  host_id_before["$app"]="$(host_id "$app")"
  log_step "$app: ${records_before[$app]} records, host ID '${host_id_before[$app]}'"
done

restarted_at="$(utc_now)"
for app in "${apps[@]}"; do
  kubectl rollout restart deployment "$app" --namespace functions >&2
done
for app in "${apps[@]}"; do
  wait_for_rollout "$app"
done
log_step "rollouts complete; watching for ${wait_seconds}s"
sleep "$wait_seconds"

markdown_row Run App 'Records before' 'Records after' 'Host ID before' 'Host ID after' 'Processings since restart'
markdown_separator 7
for app in "${apps[@]}"; do
  records_after="$(total_record_count "$app")"
  host_id_after="$(host_id "$app")"
  IFS=$'\t' read -r processings duplicates < <(processings_since "$app" "$restarted_at")
  if [[ "$records_after" != "${records_before[$app]}" ]]; then
    fail_expectation "$app: the record count changed from ${records_before[$app]} to $records_after"
  fi
  if [[ -z "$host_id_after" || "$host_id_after" != "${host_id_before[$app]}" ]]; then
    fail_expectation "$app: the host ID is '$host_id_after' (was '${host_id_before[$app]}')"
  fi
  if ((processings > 0)); then
    fail_expectation "$app: $processings processing(s) since the restart ($duplicates duplicate)"
  fi
  markdown_row "$RUN_ID" "$app" "${records_before[$app]}" "$records_after" "\`${host_id_before[$app]}\`" \
    "\`${host_id_after}\`" "$processings ($duplicates)"
done
finish_scenario
