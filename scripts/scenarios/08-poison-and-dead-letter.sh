#!/usr/bin/env bash
# Scenario 08, poison and dead-letter: sends messages the apps must not process (malformed JSON, a message the queue
# trigger cannot decode, an event whose blob URL is in another storage account) to the Storage queue and to the
# Service Bus queue, and reports where each one ended: completed and logged as malformed, moved to the poison queue
# blob-events-poison, or dead-lettered in Service Bus with its reason.
#
# Informs: Q12 (poison and dead-letter handling; an event naming a blob outside the trusted account is never read).
# Changes: puts three messages in account 2's blob-events queue and sends two to the Service Bus queue blob-events.
# The dead-lettered Service Bus messages it finds are removed (completed) from the dead-letter queue; a message in
# blob-events-poison stays there (az storage message clear --queue-name blob-events-poison removes all of them).
#
# Usage: scripts/scenarios/08-poison-and-dead-letter.sh [--timeout SECONDS]
#   --timeout SECONDS  how long to wait for every message to be accounted for (default 900; Application Insights
#                      ingestion is most of it)
#   --help             prints this text
#
# Reading the result: one Markdown row per message, with where it was expected to end and where it was observed.
# Storage queue: a Base64 message whose JSON is malformed or names a foreign blob is completed and logged as
# "Malformed event completed: <reason>" (counted in Application Insights by reason, since the run started); a message
# that is not Base64 cannot be decoded by the trigger (messageEncoding base64 in host.json) and is expected in
# blob-events-poison. Service Bus: both messages are expected in the dead-letter queue with the reason MalformedEvent
# and the parser's message as description. "not seen" means not observed before the timeout. The exit status is
# non-zero when an observation differs from the expectation.
# Needs: as scenario 01 (no cluster access), plus Storage Queue Data Contributor on account 2 and Azure Service Bus
# Data Owner (send and receive) on the Service Bus queue.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

timeout_seconds=900
while (($# > 0)); do
  case "$1" in
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
require_positive_integer --timeout "$timeout_seconds"

start_scenario 08
queue_account="$(upload_account queue-triggered)"
malformed_reason="Event is malformed."
foreign_url_reason="Blob URL does not match the trusted account and subject."

# A blob name that exists nowhere, in the subject and the URL of an event, under an account the app does not trust.
foreign_url_event() {
  local foreign_account="$1"
  local blob_name="${RUN_ID}-foreign.txt"

  blob_created_event "$blob_name" "https://${foreign_account}.blob.core.windows.net/uploads/${blob_name}" \
    "${RUN_ID}-foreign-url"
}

send_storage_queue_messages() {
  local foreign_event

  foreign_event="$(foreign_url_event "$(upload_account servicebus-triggered)")"
  put_queue_message "$queue_account" blob-events "$(encode_base64 "{\"run\":\"${RUN_ID}\",")"
  put_queue_message "$queue_account" blob-events "not base64 ${RUN_ID}"
  put_queue_message "$queue_account" blob-events "$(encode_base64 "$foreign_event")"
  log_step "sent 3 messages to the Storage queue"
}

send_service_bus_messages() {
  local body_file="$SCENARIO_WORK_DIR/service-bus-message.json"

  printf '{"run":"%s",' "$RUN_ID" >"$body_file"
  service_bus_send "$body_file" "${RUN_ID}-malformed"
  foreign_url_event "$(upload_account queue-triggered)" >"$body_file"
  service_bus_send "$body_file" "${RUN_ID}-foreign-url"
  log_step "sent 2 messages to the Service Bus queue"
}

# Prints the number of "Malformed event completed" log lines with the reason since the run started.
completed_malformed_count() {
  local reason="$1"
  local query

  query=$(
    cat <<KUSTO
traces
| where timestamp >= datetime(${RUN_STARTED_AT})
| where message startswith "Malformed event completed"
| where tostring(customDimensions["reason"]) == "${reason}"
| count
KUSTO
  )
  app_insights_rows "$query"
}

# Succeeds when blob-events-poison holds a message carrying this run's ID.
is_in_poison_queue() {
  local content

  while IFS= read -r content; do
    if [[ "$(decode_queue_message "$content")" == *"$RUN_ID"* ]]; then
      return 0
    fi
  done < <(peek_queue_messages "$queue_account" blob-events-poison)
  return 1
}

# Locks the messages of the dead-letter queue one by one; records this run's ones in the dead-letter file as
# "<message id>\t<reason>\t<description>" and completes them; unlocks every other one.
collect_dead_letters() {
  local dead_letter_file="$1"
  local headers_file="$SCENARIO_WORK_DIR/dead-letter.headers"
  local body_file="$SCENARIO_WORK_DIR/dead-letter.body"
  local message_id
  local location
  local -a other_messages=()

  while service_bus_peek_lock "$(service_bus_queue_url)/\$deadletterqueue" "$headers_file" "$body_file"; do
    message_id="$(broker_message_id "$headers_file")"
    location="$(response_header Location "$headers_file")"
    if [[ "$message_id" != "${RUN_ID}-"* ]]; then
      other_messages+=("$location")
      continue
    fi
    printf '%s\t%s\t%s\n' "$message_id" "$(response_header DeadLetterReason "$headers_file")" \
      "$(response_header DeadLetterErrorDescription "$headers_file")" >>"$dead_letter_file"
    service_bus_complete "$location"
  done
  for location in "${other_messages[@]}"; do
    service_bus_release "$location"
  done
}

# Prints "dead-lettered: <reason>, <description>" for the message, or "not seen".
dead_letter_observation() {
  local dead_letter_file="$1"
  local message_id="$2"
  local reason
  local description

  IFS=$'\t' read -r _ reason description < <(grep -F "${message_id}"$'\t' "$dead_letter_file") || {
    printf 'not seen'
    return
  }
  printf 'dead-lettered: %s, %s' "$reason" "$description"
}

send_storage_queue_messages
send_service_bus_messages

dead_letter_file="$SCENARIO_WORK_DIR/dead-letters.tsv"
: >"$dead_letter_file"
deadline=$((SECONDS + timeout_seconds))
while true; do
  malformed_completed="$(completed_malformed_count "$malformed_reason")"
  foreign_completed="$(completed_malformed_count "$foreign_url_reason")"
  poisoned=false
  ! is_in_poison_queue || poisoned=true
  collect_dead_letters "$dead_letter_file"
  dead_lettered="$(wc -l <"$dead_letter_file")"
  log_step "completed as malformed: ${malformed_completed:-0} + ${foreign_completed:-0}/2, poison: $poisoned," \
    "dead-lettered: $dead_lettered/2"
  if ((${malformed_completed:-0} >= 1 && ${foreign_completed:-0} >= 1 && dead_lettered >= 2)) &&
    [[ "$poisoned" == true ]]; then
    break
  fi
  if ((SECONDS >= deadline)); then
    break
  fi
  sleep 30
done

completed_observation() {
  local found="${1:-0}"

  if ((found == 0)); then
    printf 'not seen'
    return
  fi
  printf 'completed, logged %s time(s)' "$found"
}

storage_queue_rows() {
  local malformed_seen
  local foreign_seen
  local poison_seen="not seen"

  malformed_seen="$(completed_observation "$malformed_completed")"
  foreign_seen="$(completed_observation "$foreign_completed")"
  [[ "$poisoned" != true ]] || poison_seen="in blob-events-poison"
  [[ "$malformed_seen" != "not seen" ]] || fail_expectation "Storage queue: malformed JSON not logged as completed"
  [[ "$foreign_seen" != "not seen" ]] || fail_expectation "Storage queue: foreign URL not logged as completed"
  [[ "$poisoned" == true ]] || fail_expectation "Storage queue: the non-Base64 message is not in the poison queue"
  markdown_row "$RUN_ID" 'Storage queue' 'malformed JSON (Base64)' \
    "completed, logged \"${malformed_reason}\"" "$malformed_seen"
  markdown_row "$RUN_ID" 'Storage queue' 'not Base64' 'in blob-events-poison' "$poison_seen"
  markdown_row "$RUN_ID" 'Storage queue' 'blob URL in another account (Base64)' \
    "completed, logged \"${foreign_url_reason}\"" "$foreign_seen"
}

service_bus_row() {
  local message_label="$1"
  local message_id="$2"
  local reason="$3"
  local expected="dead-lettered: MalformedEvent, ${reason}"
  local observed

  observed="$(dead_letter_observation "$dead_letter_file" "$message_id")"
  [[ "$observed" == "$expected" ]] || fail_expectation "Service Bus: $message_label: $observed"
  markdown_row "$RUN_ID" 'Service Bus' "$message_label" "$expected" "$observed"
}

markdown_row Run Path Message Expected Observed
markdown_separator 5
storage_queue_rows
service_bus_row 'malformed JSON' "${RUN_ID}-malformed" "$malformed_reason"
service_bus_row 'blob URL in another account' "${RUN_ID}-foreign-url" "$foreign_url_reason"
finish_scenario
