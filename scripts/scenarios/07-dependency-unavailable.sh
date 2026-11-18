#!/usr/bin/env bash
# Scenario 07, dependency unavailable: cuts one app's network egress for a while (storage, Service Bus, Entra ID and
# DNS all unreachable), uploads blobs during the outage, restores the network, then checks that every blob was
# processed exactly once and reports how long after the restore it took.
#
# Informs: Q12 (a dependency briefly unavailable: retries, no lost or doubled blob), Q9 (the delay it adds).
# Changes: NetworkPolicies are additive (a pod's allowed traffic is the union of the policies that select it), so a
# deny-all policy alone cannot narrow the shared default-deny-egress, which allows DNS and HTTPS to every pod. The
# scenario therefore (1) patches default-deny-egress to select every pod except the app's, and (2) adds a deny-all
# egress policy for the app, labelled scenario=dependency-unavailable. It restores both on exit, also on failure:
# deletes the labelled policy and puts back the podSelector {} of default-deny-egress (k8s/network-policy.yaml).
# Uploads the blobs (left in place).
#
# Usage: scripts/scenarios/07-dependency-unavailable.sh [--app APP] [--count N] [--outage SECONDS]
#                                                       [--timeout SECONDS] [--ingestion-timeout SECONDS]
#   --app APP                    blob-polling, queue-triggered or servicebus-triggered (default: all three, in turn)
#   --count N                    blobs uploaded during the outage, per app (default 10)
#   --outage SECONDS             how long egress stays blocked (default 60)
#   --timeout SECONDS            how long to wait for the records after the restore, per app (default 900)
#   --ingestion-timeout SECONDS  how long to wait for Application Insights, per app (default 600)
#   --help                       prints this text
#
# Reading the result: one Markdown row per app. "Records during outage" should be 0: a non-zero value means the
# policy did not cut the app off (connections opened before the policy may survive it, depending on the network
# policy engine). "Processed after restore" is the time from the restore until every blob had its record; "Max
# latency" is upload to processed for the slowest blob. "Retries" counts the extra invocations Application Insights
# saw. Expected: "Records" N/N and no blob processed twice without being logged as a duplicate; the exit status is
# non-zero otherwise. The logs of the outage itself reach Application Insights only after it (from the pod's buffer),
# if at all.
# Needs: as scenario 01, plus the cluster (scripts/kubeconfig.sh) with the right to manage NetworkPolicies in
# "functions", and the cluster's network policy engine (Cilium, infra/aks.tf).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

apps=(blob-polling queue-triggered servicebus-triggered)
count=10
outage_seconds=60
timeout_seconds=900
ingestion_timeout_seconds=600
while (($# > 0)); do
  case "$1" in
    --app) require_app "${2:?--app needs a value}"; apps=("$2"); shift 2 ;;
    --count) count="${2:?--count needs a value}"; shift 2 ;;
    --outage) outage_seconds="${2:?--outage needs a value}"; shift 2 ;;
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --ingestion-timeout) ingestion_timeout_seconds="${2:?--ingestion-timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --count "$count"
require_positive_integer --outage "$outage_seconds"
require_positive_integer --timeout "$timeout_seconds"
require_positive_integer --ingestion-timeout "$ingestion_timeout_seconds"

# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/../kubeconfig.sh"

start_scenario 07

block_egress() {
  local app="$1"

  local every_other_app="{\"matchExpressions\":[{\"key\":\"app\",\"operator\":\"NotIn\",\"values\":[\"${app}\"]}]}"

  kubectl patch networkpolicy default-deny-egress --namespace functions --type merge \
    --patch "{\"spec\":{\"podSelector\":${every_other_app}}}" >&2
  kubectl apply --filename - >&2 <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: scenario-outage-${app}
  namespace: functions
  labels:
    scenario: dependency-unavailable
spec:
  podSelector:
    matchLabels:
      app: ${app}
  policyTypes:
    - Egress
  egress: []
YAML
}

# A JSON patch replaces the whole podSelector; a merge patch or kubectl apply would keep the matchExpressions.
restore_egress() {
  kubectl delete networkpolicy --namespace functions --selector scenario=dependency-unavailable \
    --ignore-not-found >&2 || true
  kubectl patch networkpolicy default-deny-egress --namespace functions --type json \
    --patch '[{"op":"replace","path":"/spec/podSelector","value":{}}]' >&2 || true
}

restore_egress_and_clean_up() {
  restore_egress
  remove_work_dir
}
trap restore_egress_and_clean_up EXIT

# Prints the seconds from the restore until every blob of the app has its record, or "n/a" after the timeout.
seconds_until_processed() {
  local app="$1"
  local restored_at=$SECONDS

  if ! wait_until_processed "$app" "$timeout_seconds"; then
    printf 'n/a'
    return
  fi
  printf '%s' "$((SECONDS - restored_at))"
}

declare -A records_during_outage processed_after_restore
for app in "${apps[@]}"; do
  log_step "$app: blocking egress for ${outage_seconds}s"
  outage_started=$SECONDS
  block_egress "$app"
  # Gives the network policy engine a moment to program the rules before the upload.
  sleep 5
  upload_blobs "$app" "$count" "$count"
  remaining=$((outage_seconds - (SECONDS - outage_started)))
  ((remaining <= 0)) || sleep "$remaining"
  records_during_outage["$app"]="$(found_record_count "$app")"
  restore_egress
  log_step "$app: egress restored after $((SECONDS - outage_started))s"
  if ((records_during_outage[$app] > 0)); then
    fail_expectation "$app: ${records_during_outage[$app]} blob(s) processed during the outage" \
      "(the policy did not cut the app off)"
  fi
  processed_after_restore["$app"]="$(seconds_until_processed "$app")"
done
for app in "${apps[@]}"; do
  wait_for_processing_rows "$app" "$ingestion_timeout_seconds" ||
    log_step "$app: not every blob is in Application Insights after ${ingestion_timeout_seconds}s"
done

markdown_row Run App Blobs 'Outage (s)' 'Records during outage' 'Processed after restore (s)' 'Max latency (ms)' \
  Records Retries Duplicates
markdown_separator 10
for app in "${apps[@]}"; do
  rows_file="$(processing_rows_file "$app")"
  IFS=$'\t' read -r _ _ _ maximum _ < <(latency_distribution "$rows_file")
  check_single_processing "$app"
  markdown_row "$RUN_ID" "$app" "$count" "$outage_seconds" "${records_during_outage[$app]}" \
    "${processed_after_restore[$app]}" "$maximum" "$(check_records "$app")" "$(retry_count "$rows_file")" \
    "$(column_sum "$rows_file" 5)"
done
finish_scenario
