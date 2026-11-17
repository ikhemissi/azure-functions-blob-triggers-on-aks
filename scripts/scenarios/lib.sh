#!/usr/bin/env bash
# Shared steps of the test scenarios (scripts/scenarios/NN-*.sh): options, uploads, processing records, Application
# Insights queries, Kubernetes and Service Bus helpers, and the Markdown summary. Builds on scripts/common.sh.
# Sourcing it needs no Azure access (so that --help works offline); the functions call az, curl and kubectl.
# Linux tools assumed: GNU date and base64, curl 7.84 or later (for -w '%header{...}').
set -euo pipefail

SCENARIOS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCENARIOS_DIR/../common.sh"

STORAGE_API_VERSION="2023-11-03"

# ---------------------------------------------------------------------------------------------------------------------
# Options and output

# Prints the header comment of a scenario script: its purpose, question, changes, options and how to read the result.
print_help() {
  local script="$1"
  local line

  while IFS= read -r line; do
    [[ "$line" == '#!'* ]] && continue
    [[ "$line" == '#'* ]] || break
    line="${line#\#}"
    printf '%s\n' "${line# }"
  done <"$script"
}

require_positive_integer() {
  local option="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s needs a positive integer, got "%s"\n' "$option" "$value" >&2
    exit 2
  fi
}

require_app() {
  app_number "$1" >/dev/null || exit 2
}

# Starts a run: a unique blob-name prefix, the start time and a private working directory removed on exit.
# Scenarios that change the cluster replace the EXIT trap with one that restores it, then calls remove_work_dir.
start_scenario() {
  local scenario_number="$1"

  RUN_ID="s${scenario_number}-$(date -u +'%Y%m%dt%H%M%S')"
  RUN_START_EPOCH="$(date -u +%s)"
  RUN_STARTED_AT="$(date -u -d "@${RUN_START_EPOCH}" +'%Y-%m-%dT%H:%M:%SZ')"
  # Five minutes earlier than the start, so that a clock difference with Azure never hides a record or a log line.
  RUN_QUERY_SINCE="$(date -u -d "@$((RUN_START_EPOCH - 300))" +'%Y-%m-%dT%H:%M:%SZ')"
  SCENARIO_WORK_DIR="$(mktemp -d)"
  trap remove_work_dir EXIT
  printf 'Run %s started %s (azd environment %s)\n' "$RUN_ID" "$RUN_STARTED_AT" "$(azd_value AZURE_ENV_NAME)" >&2
}

utc_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

remove_work_dir() {
  rm -rf "${SCENARIO_WORK_DIR:?}"
}

log_step() {
  printf '[%s] %s\n' "$(date -u +'%H:%M:%S')" "$*" >&2
}

# Failures go to a file rather than a variable, so that a check run in a command substitution or a background job
# (a subshell) still counts.
fail_expectation() {
  printf 'EXPECTATION FAILED: %s\n' "$*" >&2
  printf '%s\n' "$*" >>"$SCENARIO_WORK_DIR/failed-expectations"
}

markdown_row() {
  local cell
  local row="|"

  for cell in "$@"; do
    row+=" ${cell} |"
  done
  printf '%s\n' "$row"
}

# Prints the separator line under a Markdown header row of the given number of columns.
markdown_separator() {
  local columns="$1"
  local index
  local row="|"

  for ((index = 0; index < columns; index++)); do
    row+="---|"
  done
  printf '%s\n' "$row"
}

finish_scenario() {
  local failed_expectations=0

  if [[ -e "$SCENARIO_WORK_DIR/failed-expectations" ]]; then
    failed_expectations="$(wc -l <"$SCENARIO_WORK_DIR/failed-expectations")"
  fi
  if ((failed_expectations > 0)); then
    printf '%s expectation(s) failed\n' "$failed_expectations" >&2
    exit 1
  fi
  echo "All expectations met." >&2
}

# ---------------------------------------------------------------------------------------------------------------------
# Uploads (the Entra token goes in a header file, so that it never shows in the process list)

# Writes an Authorization header with an Entra token for the resource to a working-directory file; prints its path.
bearer_header_file() {
  local resource="$1"
  local file_name="$2"
  local header_file="$SCENARIO_WORK_DIR/$file_name"
  local token

  token="$(az account get-access-token --resource "$resource" --query accessToken --output tsv)"
  printf 'Authorization: %s %s\n' Bearer "$token" >"$header_file"
  printf '%s' "$header_file"
}

blob_prefix() {
  local app="$1"

  printf '%s-%s-' "$RUN_ID" "$app"
}

blob_manifest() {
  printf '%s/%s.blobs' "$SCENARIO_WORK_DIR" "$1"
}

# Uploads one blob with the Blob service REST API and appends "<name><TAB><ETag>" to the app's manifest.
upload_one_blob() {
  local account="$1"
  local blob_name="$2"
  local header_file="$3"
  local manifest="$4"
  local etag

  etag="$(printf 'scenario blob %s\n' "$blob_name" |
    curl --silent --show-error --fail \
      --request PUT \
      --header @"$header_file" \
      --header "x-ms-version: $STORAGE_API_VERSION" \
      --header 'x-ms-blob-type: BlockBlob' \
      --header 'Content-Type: text/plain' \
      --data-binary @- \
      --output /dev/null \
      --write-out '%header{etag}' \
      "https://${account}.blob.core.windows.net/uploads/${blob_name}")"
  printf '%s\t%s\n' "$blob_name" "$etag" >>"$manifest"
}

# Uploads <count> blobs named <run>-<app>-NNNN.txt to the app's upload account, <parallelism> at a time.
# Call it once per app and run: the manifest lists every blob with its ETag, for the idempotency row keys.
upload_blobs() {
  local app="$1"
  local count="$2"
  local parallelism="$3"
  local account
  local header_file
  local manifest
  local index
  local blob_name
  local pid
  local -a wave=()

  account="$(upload_account "$app")"
  header_file="$(bearer_header_file https://storage.azure.com/ "storage-upload-$app.header")"
  manifest="$(blob_manifest "$app")"
  : >"$manifest"
  for ((index = 1; index <= count; index++)); do
    blob_name="$(blob_prefix "$app")$(printf '%04d' "$index").txt"
    upload_one_blob "$account" "$blob_name" "$header_file" "$manifest" &
    wave+=("$!")
    if ((${#wave[@]} == parallelism || index == count)); then
      for pid in "${wave[@]}"; do
        wait "$pid"
      done
      wave=()
    fi
  done
  log_step "uploaded $count blob(s) to $app ($account)"
  write_expected_row_keys "$app"
}

# ---------------------------------------------------------------------------------------------------------------------
# Processing records (table `processed` in the app's host account; one row per processed blob version)

expected_row_keys_file() {
  printf '%s/%s.rowkeys' "$SCENARIO_WORK_DIR" "$1"
}

write_expected_row_keys() {
  local app="$1"
  local account
  local blob_name
  local etag
  local row_keys_file

  account="$(upload_account "$app")"
  row_keys_file="$(expected_row_keys_file "$app")"
  : >"$row_keys_file"
  while IFS=$'\t' read -r blob_name etag; do
    processed_row_key "$account" "$blob_name" "$etag" >>"$row_keys_file"
  done <"$(blob_manifest "$app")"
  sort -o "$row_keys_file" "$row_keys_file"
}

# Prints, sorted, the row keys the app recorded since the run started (the Azure CLI reads every page).
recorded_row_keys() {
  local app="$1"

  az storage entity query \
    --account-name "$(host_account "$app")" \
    --table-name processed \
    --auth-mode login \
    --filter "PartitionKey eq '${app}' and Timestamp ge datetime'${RUN_QUERY_SINCE}'" \
    --select RowKey \
    --query 'items[].RowKey' \
    --output tsv |
    sort
}

# Prints how many of this run's blobs for the app have their processing record.
found_record_count() {
  local app="$1"

  comm -12 "$(expected_row_keys_file "$app")" <(recorded_row_keys "$app") | wc -l
}

# Counts the app's records written since the run started, matched or not; usable while the upload is still running
# (before the expected row keys exist). Assumes no other run uploads to the app at the same time.
recent_record_count() {
  recorded_row_keys "$1" | wc -l
}

expected_blob_count() {
  wc -l <"$(expected_row_keys_file "$1")"
}

# Waits until every blob of this run for the app has its record; returns 1 after <timeout> seconds.
wait_until_processed() {
  local app="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  local expected
  local found

  expected="$(expected_blob_count "$app")"
  while true; do
    found="$(found_record_count "$app")"
    log_step "$app: $found/$expected processing records"
    if ((found == expected)); then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 5
  done
}

# Prints "found/expected" records for this run's blobs of the app; fails an expectation unless every blob has one.
# The table's key (app, SHA-256 of the idempotency key) allows at most one record per blob version.
check_records() {
  local app="$1"
  local expected
  local found

  expected="$(expected_blob_count "$app")"
  found="$(found_record_count "$app")"
  if ((found != expected)); then
    fail_expectation "$app: $found of $expected blobs have their processing record"
  fi
  printf '%s/%s' "$found" "$expected"
}

# Prints the number of records the app has in its table (every run).
total_record_count() {
  local app="$1"

  az storage entity query \
    --account-name "$(host_account "$app")" \
    --table-name processed \
    --auth-mode login \
    --filter "PartitionKey eq '${app}'" \
    --select RowKey \
    --query 'length(items)' \
    --output tsv
}

# ---------------------------------------------------------------------------------------------------------------------
# Application Insights (the apps' structured logs; ingestion takes a few minutes)

app_insights_rows() {
  local query="$1"

  if [[ -z "${APPLICATION_INSIGHTS_RESOURCE_ID:-}" ]]; then
    APPLICATION_INSIGHTS_RESOURCE_ID="$(azd_value APPLICATION_INSIGHTS_ID)"
  fi
  az monitor app-insights query \
    --ids "$APPLICATION_INSIGHTS_RESOURCE_ID" \
    --analytics-query "$query" \
    --offset 24h \
    --query 'tables[0].rows' \
    --output tsv
}

processing_rows_file() {
  printf '%s/%s.processing' "$SCENARIO_WORK_DIR" "$1"
}

# Writes one tab-separated line per blob of this run for the app, from its log lines (docs/DESIGN.md, Processing):
#   1 blob  2 pod  3 latency in ms (first processing)  4 first processings (duplicate=false)
#   5 duplicates (duplicate=true)  6 invocations (distinct invocation IDs: 1, plus retries and redeliveries)
write_processing_rows() {
  local app="$1"
  local query

  query=$(
    cat <<KUSTO
traces
| where timestamp >= datetime(${RUN_QUERY_SINCE})
| where tostring(customDimensions["app"]) == "${app}"
| extend blobName = tostring(customDimensions["blobName"])
| where blobName startswith "$(blob_prefix "$app")"
| extend podName = tostring(customDimensions["podName"])
| extend invocationId = tostring(customDimensions["invocationId"])
| extend latencyMs = todouble(customDimensions["latencyMs"])
| extend isDuplicate = tolower(tostring(customDimensions["duplicate"])) == "true"
| extend isFinished = isnotnull(latencyMs)
| extend isFirstProcessing = isFinished and not(isDuplicate)
| summarize pod = take_anyif(podName, isFirstProcessing),
            latencyMs = tolong(round(minif(latencyMs, isFirstProcessing))),
            firstProcessings = countif(isFirstProcessing),
            duplicates = countif(isFinished and isDuplicate),
            invocations = array_length(make_set(invocationId))
            by blobName
| order by blobName asc
KUSTO
  )
  app_insights_rows "$query" >"$(processing_rows_file "$app")"
}

# Waits until Application Insights shows a finished processing for every blob of this run for the app.
# Returns 1 after <timeout> seconds; the rows file then holds what was ingested so far.
wait_for_processing_rows() {
  local app="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  local expected
  local logged

  expected="$(expected_blob_count "$app")"
  while true; do
    write_processing_rows "$app"
    logged="$(awk -F '\t' '$4 ~ /^[0-9]+$/ && $4 >= 1' "$(processing_rows_file "$app")" | wc -l)"
    log_step "$app: $logged/$expected blobs logged in Application Insights"
    if ((logged >= expected)); then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 30
  done
}

# Prints "<min> <median> <p95> <max> <count>" (tab-separated, nearest rank) of the latencies in a rows file.
latency_distribution() {
  local rows_file="$1"
  local -a latencies
  local count
  local median_index
  local p95_index

  mapfile -t latencies < <(cut -f 3 "$rows_file" | grep -E '^-?[0-9]+$' | sort -n)
  count="${#latencies[@]}"
  if ((count == 0)); then
    printf 'n/a\tn/a\tn/a\tn/a\t0\n'
    return
  fi
  median_index=$(((count + 1) / 2 - 1))
  p95_index=$(((95 * count + 99) / 100 - 1))
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${latencies[0]}" "${latencies[median_index]}" "${latencies[p95_index]}" "${latencies[count - 1]}" "$count"
}

# Prints the sum of one column (1-based) of a rows file; empty or null cells count as 0.
column_sum() {
  local rows_file="$1"
  local column="$2"

  awk -F '\t' -v column="$column" '$column ~ /^[0-9]+$/ { total += $column } END { print total + 0 }' "$rows_file"
}

# Prints the retries and redeliveries in a rows file: the invocations beyond the first, per blob.
retry_count() {
  awk -F '\t' '$6 ~ /^[0-9]+$/ && $6 > 1 { total += $6 - 1 } END { print total + 0 }' "$1"
}

# Fails an expectation for every blob that Application Insights shows processed (duplicate=false) more than once.
check_single_processing() {
  local app="$1"
  local processed_twice

  processed_twice="$(awk -F '\t' '$4 ~ /^[0-9]+$/ && $4 > 1' "$(processing_rows_file "$app")" | wc -l)"
  if ((processed_twice > 0)); then
    fail_expectation "$app: $processed_twice blob(s) processed more than once without being logged as duplicates"
  fi
}

# ---------------------------------------------------------------------------------------------------------------------
# Kubernetes (source scripts/kubeconfig.sh first)

ready_replicas() {
  local ready

  ready="$(kubectl get deployment "$1" --namespace functions --output 'jsonpath={.status.readyReplicas}')"
  printf '%s' "${ready:-0}"
}

desired_replicas() {
  kubectl get deployment "$1" --namespace functions --output 'jsonpath={.spec.replicas}'
}

wait_for_rollout() {
  kubectl rollout status deployment "$1" --namespace functions --timeout=600s >&2
}

wait_for_no_pods() {
  kubectl wait pod --namespace functions --selector "app=$1" --for=delete --timeout=300s >&2
}

# Pauses KEDA for the app at zero replicas (the ScaledObject annotation), so that its queue keeps the messages.
pause_keda_at_zero() {
  local app="$1"

  kubectl annotate scaledobject "$app" --namespace functions --overwrite \
    autoscaling.keda.sh/paused-replicas=0 >&2
  wait_for_no_pods "$app"
}

# Removes the pause annotation (KEDA scales the app again); does nothing when the annotation is absent.
resume_keda() {
  kubectl annotate scaledobject "$1" --namespace functions autoscaling.keda.sh/paused-replicas- >&2 || true
}

# ---------------------------------------------------------------------------------------------------------------------
# Messages: the Storage queue (account 2) and Service Bus (REST API with an Entra token)

# Prints the approximate message count of a Storage queue (Get Queue Metadata).
storage_queue_length() {
  local account="$1"
  local queue="$2"
  local header_file

  header_file="$(bearer_header_file https://storage.azure.com/ storage-queue.header)"
  curl --silent --show-error --fail \
    --head \
    --header @"$header_file" \
    --header "x-ms-version: $STORAGE_API_VERSION" \
    --output /dev/null \
    --write-out '%header{x-ms-approximate-messages-count}' \
    "https://${account}.queue.core.windows.net/${queue}?comp=metadata"
}

# Puts a message in a Storage queue as is: the Azure CLI does not encode it (the caller encodes it if needed).
put_queue_message() {
  local account="$1"
  local queue="$2"
  local content="$3"

  az storage message put \
    --account-name "$account" \
    --queue-name "$queue" \
    --content "$content" \
    --auth-mode login \
    --only-show-errors \
    --output none
}

# Prints the raw content of up to 32 messages of a Storage queue, one per line, without dequeuing them.
# Prints nothing when the queue does not exist (e.g. the poison queue before its first message).
peek_queue_messages() {
  local account="$1"
  local queue="$2"

  az storage message peek \
    --account-name "$account" \
    --queue-name "$queue" \
    --num-messages 32 \
    --auth-mode login \
    --only-show-errors \
    --query '[].content' \
    --output tsv 2>/dev/null || true
}

# Prints the text of a queue message: decoded when it is Base64 of a JSON value, as is otherwise.
decode_queue_message() {
  local content="$1"
  local decoded

  if decoded="$(printf '%s' "$content" | base64 --decode 2>/dev/null)" && [[ "$decoded" == [\{\[]* ]]; then
    printf '%s' "$decoded"
    return
  fi
  printf '%s' "$content"
}

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

service_bus_queue_url() {
  printf 'https://%s.servicebus.windows.net/blob-events' "$(azd_value SERVICE_BUS_NAMESPACE)"
}

service_bus_header_file() {
  bearer_header_file https://servicebus.azure.net service-bus.header
}

# Sends the body file to the Service Bus queue with the given message ID.
service_bus_send() {
  local body_file="$1"
  local message_id="$2"

  curl --silent --show-error --fail \
    --request POST \
    --header @"$(service_bus_header_file)" \
    --header 'Content-Type: application/json' \
    --header "BrokerProperties: {\"MessageId\":\"${message_id}\"}" \
    --data-binary @"$body_file" \
    --output /dev/null \
    "$(service_bus_queue_url)/messages"
}

# Locks the next unlocked message of a Service Bus entity URL (the queue, or its "/$deadletterqueue") and writes its
# response headers and body to files. Returns 1 when there is none. Release or complete it with its Location header.
service_bus_peek_lock() {
  local entity_url="$1"
  local headers_file="$2"
  local body_file="$3"
  local status

  status="$(curl --silent --show-error \
    --request POST \
    --header @"$(service_bus_header_file)" \
    --header 'Content-Length: 0' \
    --dump-header "$headers_file" \
    --output "$body_file" \
    --write-out '%{http_code}' \
    "${entity_url}/messages/head?timeout=5")"
  [[ "$status" == 201 ]]
}

# Prints a response header's value from a headers file, without the quotes of Service Bus string properties.
response_header() {
  local name="$1"
  local headers_file="$2"

  { grep -i "^${name}:" "$headers_file" || true; } |
    head -n 1 |
    cut -d ':' -f 2- |
    tr -d '\r' |
    sed -e 's/^ *//' -e 's/^"//' -e 's/"$//'
}

# Prints the MessageId from a peek-lock response's BrokerProperties header.
broker_message_id() {
  response_header BrokerProperties "$1" | sed -n 's/.*"MessageId":"\([^"]*\)".*/\1/p'
}

# Unlocks a peek-locked message: it becomes available again, with its delivery count incremented.
service_bus_release() {
  curl --silent --show-error --fail --request PUT --header @"$(service_bus_header_file)" \
    --header 'Content-Length: 0' --output /dev/null "$1"
}

# Completes (removes) a peek-locked message.
service_bus_complete() {
  curl --silent --show-error --fail --request DELETE --header @"$(service_bus_header_file)" \
    --output /dev/null "$1"
}

# Prints an Event Grid BlobCreated event (Event Grid schema) for a blob of the uploads container at <blob url>.
blob_created_event() {
  local blob_name="$1"
  local blob_url="$2"
  local event_id="$3"

  printf '{"id":"%s","subject":"/blobServices/default/containers/uploads/blobs/%s",' "$event_id" "$blob_name"
  printf '"eventType":"Microsoft.Storage.BlobCreated","eventTime":"%s",' "$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')"
  printf '"data":{"api":"PutBlob","url":"%s","contentType":"text/plain","contentLength":1,' "$blob_url"
  printf '"blobType":"BlockBlob"},"dataVersion":"","metadataVersion":"1"}'
}
