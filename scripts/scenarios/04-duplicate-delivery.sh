#!/usr/bin/env bash
# Scenario 04, duplicate delivery: captures a real BlobCreated event as Event Grid delivered it (KEDA paused at zero
# replicas so that the message stays in the queue), lets the app process it, then sends a copy of the same event
# again, as an Event Grid redelivery would, and checks that the second processing is logged as a duplicate and that
# the blob still has one processing record. Apps queue-triggered (Storage queue) and servicebus-triggered (Service Bus).
#
# Informs: Q12 (Event Grid redelivery, idempotency record), Q5 (the encoding Event Grid uses in the Storage queue).
# Changes: pauses each app's ScaledObject at zero replicas (annotation autoscaling.keda.sh/paused-replicas=0) while it
# captures the event, then removes the annotation (also on exit, on failure); uploads one blob per app and sends one
# copy of its event to the app's queue. The Service Bus capture peek-locks then unlocks the message (delivery count +1).
#
# Usage: scripts/scenarios/04-duplicate-delivery.sh [--timeout SECONDS] [--ingestion-timeout SECONDS]
#   --timeout SECONDS            how long to wait for the event in the queue and for the record (default 600)
#   --ingestion-timeout SECONDS  how long to wait for the duplicate in Application Insights (default 900)
#   --help                       prints this text
#
# Reading the result: one Markdown row per app. "Original encoding" is how the captured Storage queue message was
# encoded (base64 or text; the copy is sent Base64-encoded, as host.json's messageEncoding expects); for Service Bus,
# the copy reuses the original message ID. Expected: "First processings" 1, "Duplicates logged" at least 1, "Records"
# 1/1. The exit status is non-zero otherwise.
# Needs: as scenario 01, plus the cluster (scripts/kubeconfig.sh), Storage Queue Data Contributor on account 2 and
# Azure Service Bus Data Owner (send and receive) on the Service Bus queue.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

timeout_seconds=600
ingestion_timeout_seconds=900
while (($# > 0)); do
  case "$1" in
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --ingestion-timeout) ingestion_timeout_seconds="${2:?--ingestion-timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --timeout "$timeout_seconds"
require_positive_integer --ingestion-timeout "$ingestion_timeout_seconds"

# shellcheck source=scripts/kubeconfig.sh
source "$SCRIPT_DIR/../kubeconfig.sh"

apps=(queue-triggered servicebus-triggered)
start_scenario 04
restore_keda() {
  resume_keda queue-triggered
  resume_keda servicebus-triggered
  remove_work_dir
}
trap restore_keda EXIT

# Prints the raw content of the Storage queue message whose event names the blob.
capture_storage_queue_event() {
  local blob_name="$1"
  local deadline=$((SECONDS + timeout_seconds))
  local account
  local content

  account="$(upload_account queue-triggered)"
  while ((SECONDS < deadline)); do
    while IFS= read -r content; do
      if [[ "$(decode_queue_message "$content")" == *"$blob_name"* ]]; then
        printf '%s' "$content"
        return 0
      fi
    done < <(peek_queue_messages "$account" blob-events)
    sleep 5
  done
  return 1
}

# Writes the body of the Service Bus message whose event names the blob to <body file> and prints its message ID.
# Every message it locks is unlocked again.
capture_service_bus_event() {
  local blob_name="$1"
  local body_file="$2"
  local deadline=$((SECONDS + timeout_seconds))
  local headers_file="$SCENARIO_WORK_DIR/capture.headers"
  local candidate_file="$SCENARIO_WORK_DIR/capture.body"
  local message_id=""
  local location
  local -a locked_messages

  while [[ -z "$message_id" ]] && ((SECONDS < deadline)); do
    locked_messages=()
    while service_bus_peek_lock "$(service_bus_queue_url)" "$headers_file" "$candidate_file"; do
      locked_messages+=("$(response_header Location "$headers_file")")
      if grep -qF "$blob_name" "$candidate_file"; then
        cp "$candidate_file" "$body_file"
        message_id="$(broker_message_id "$headers_file")"
        break
      fi
    done
    for location in "${locked_messages[@]}"; do
      service_bus_release "$location"
    done
    [[ -n "$message_id" ]] || sleep 5
  done
  [[ -n "$message_id" ]] || return 1
  printf '%s' "$message_id"
}

# Waits until Application Insights shows a processing logged duplicate=true for the app's blob of this run.
wait_for_duplicate() {
  local app="$1"
  local deadline=$((SECONDS + ingestion_timeout_seconds))

  while true; do
    write_processing_rows "$app"
    if (($(column_sum "$(processing_rows_file "$app")" 5) >= 1)); then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      return 1
    fi
    log_step "$app: waiting for the duplicate in Application Insights"
    sleep 30
  done
}

declare -A original_detail copy_sent_at
for app in "${apps[@]}"; do
  pause_keda_at_zero "$app"
  upload_blobs "$app" 1 1
  blob_name="$(cut -f 1 "$(blob_manifest "$app")")"
  if [[ "$app" == queue-triggered ]]; then
    original_message="$(capture_storage_queue_event "$blob_name")" || {
      fail_expectation "$app: no event for $blob_name in the Storage queue after ${timeout_seconds}s"
      resume_keda "$app"
      continue
    }
    event_json="$(decode_queue_message "$original_message")"
    original_detail["$app"]="base64"
    [[ "$event_json" != "$original_message" ]] || original_detail["$app"]="text"
  else
    event_file="$SCENARIO_WORK_DIR/service-bus-event.json"
    message_id="$(capture_service_bus_event "$blob_name" "$event_file")" || {
      fail_expectation "$app: no event for $blob_name in the Service Bus queue after ${timeout_seconds}s"
      resume_keda "$app"
      continue
    }
    original_detail["$app"]="message ID \`$message_id\`"
  fi
  log_step "$app: captured the event of $blob_name; resuming KEDA"
  resume_keda "$app"
  if ! wait_until_processed "$app" "$timeout_seconds"; then
    fail_expectation "$app: $blob_name was not processed after ${timeout_seconds}s"
    continue
  fi

  copy_sent_at["$app"]="$(utc_now)"
  if [[ "$app" == queue-triggered ]]; then
    put_queue_message "$(upload_account "$app")" blob-events "$(encode_base64 "$event_json")"
  else
    service_bus_send "$event_file" "$message_id"
  fi
  log_step "$app: sent the copy of the event"
  wait_for_duplicate "$app" || fail_expectation "$app: no processing logged as duplicate=true"
done

markdown_row Run App Blob 'Original encoding' 'Copy sent at' 'First processings' 'Duplicates logged' Records
markdown_separator 8
for app in "${apps[@]}"; do
  rows_file="$(processing_rows_file "$app")"
  [[ -e "$rows_file" ]] || : >"$rows_file"
  first_processings="$(column_sum "$rows_file" 4)"
  if ((first_processings != 1)); then
    fail_expectation "$app: $first_processings processings logged duplicate=false (expected 1)"
  fi
  markdown_row "$RUN_ID" "$app" "\`$(cut -f 1 "$(blob_manifest "$app")")\`" "${original_detail[$app]:-n/a}" \
    "${copy_sent_at[$app]:-n/a}" "$first_processings" "$(column_sum "$rows_file" 5)" "$(check_records "$app")"
done
finish_scenario
