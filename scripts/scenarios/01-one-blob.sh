#!/usr/bin/env bash
# Scenario 01, one blob: uploads one blob per app and reports, per app, the pod that processed it, the end-to-end
# latency (upload to processed) and its processing record.
#
# Informs: Q9 (latency for one blob), Q2 and Q4 (the three triggers work with Workload Identity).
# Changes: uploads one blob to the uploads container of each app's account (left in place). Nothing to restore.
#
# Usage: scripts/scenarios/01-one-blob.sh [--timeout SECONDS] [--ingestion-timeout SECONDS]
#   --timeout SECONDS            how long to wait for the processing records (default 600)
#   --ingestion-timeout SECONDS  how long to wait for the log lines in Application Insights (default 600)
#   --help                       prints this text
#
# Reading the result: one Markdown row per app. "Records" must be 1/1 (the record in the app's `processed` table);
# "Invocations" above 1 means a retry or a redelivery, "Duplicates" counts processings logged as duplicate=true.
# The exit status is non-zero when a blob has no record or was processed twice without being logged as a duplicate.
# Needs: az signed in (Storage Blob Data Contributor on the upload accounts, Storage Table Data Reader on the host
# accounts, reader of Application Insights), azd, curl.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

timeout_seconds=600
ingestion_timeout_seconds=600
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

apps=(blob-polling queue-triggered servicebus-triggered)
start_scenario 01

for app in "${apps[@]}"; do
  upload_blobs "$app" 1 1
done
for app in "${apps[@]}"; do
  wait_until_processed "$app" "$timeout_seconds" || log_step "$app: record still missing after ${timeout_seconds}s"
done
for app in "${apps[@]}"; do
  wait_for_processing_rows "$app" "$ingestion_timeout_seconds" ||
    log_step "$app: not in Application Insights after ${ingestion_timeout_seconds}s"
done

markdown_row Run App Blob Pod 'Latency (ms)' Records Invocations Duplicates
markdown_separator 8
for app in "${apps[@]}"; do
  blob_name="$(cut -f 1 "$(blob_manifest "$app")")"
  rows_file="$(processing_rows_file "$app")"
  pod="n/a"
  latency="n/a"
  invocations="n/a"
  duplicates="n/a"
  if [[ -s "$rows_file" ]]; then
    IFS=$'\t' read -r _ pod latency _ duplicates invocations <"$rows_file"
  fi
  records="$(check_records "$app")"
  check_single_processing "$app"
  markdown_row "$RUN_ID" "$app" "\`$blob_name\`" "${pod:-n/a}" "${latency:-n/a}" "$records" "$invocations" "$duplicates"
done
finish_scenario
