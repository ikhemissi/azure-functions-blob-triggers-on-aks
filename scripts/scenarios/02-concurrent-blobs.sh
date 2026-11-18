#!/usr/bin/env bash
# Scenario 02, concurrent blobs: uploads N blobs in parallel per app and reports the latency distribution (min,
# median, p95, max) and that every blob has exactly one processing record.
#
# Informs: Q9 (latency for concurrent blobs), Q4 (the polling trigger with 2 replicas), Q12 (one processing per blob).
# Changes: uploads N blobs to the uploads container of each app's account (left in place). Nothing to restore.
#
# Usage: scripts/scenarios/02-concurrent-blobs.sh [--count N] [--parallelism N] [--timeout SECONDS]
#                                                 [--ingestion-timeout SECONDS]
#   --count N                    blobs per app (default 20)
#   --parallelism N              uploads in flight at once (default: --count, all in parallel)
#   --timeout SECONDS            how long to wait for the processing records (default 900)
#   --ingestion-timeout SECONDS  how long to wait for the log lines in Application Insights (default 600)
#   --help                       prints this text
#
# Reading the result: one Markdown row per app. Latencies are in milliseconds, from the blob's creation to the end of
# its first processing (nearest-rank percentiles over the blobs logged in Application Insights, "Logged"). "Records"
# must be N/N; "Retries" counts invocations beyond the first per blob; "Duplicates" processings logged duplicate=true.
# The exit status is non-zero when a blob has no record or was processed twice without being logged as a duplicate.
# Needs: as scenario 01.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/scenarios/lib.sh
source "$SCRIPT_DIR/lib.sh"

count=20
parallelism=""
timeout_seconds=900
ingestion_timeout_seconds=600
while (($# > 0)); do
  case "$1" in
    --count) count="${2:?--count needs a value}"; shift 2 ;;
    --parallelism) parallelism="${2:?--parallelism needs a value}"; shift 2 ;;
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift 2 ;;
    --ingestion-timeout) ingestion_timeout_seconds="${2:?--ingestion-timeout needs a value}"; shift 2 ;;
    --help | -h) print_help "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done
parallelism="${parallelism:-$count}"
require_positive_integer --count "$count"
require_positive_integer --parallelism "$parallelism"
require_positive_integer --timeout "$timeout_seconds"
require_positive_integer --ingestion-timeout "$ingestion_timeout_seconds"

apps=(blob-polling queue-triggered servicebus-triggered)
start_scenario 02

for app in "${apps[@]}"; do
  upload_blobs "$app" "$count" "$parallelism"
done
for app in "${apps[@]}"; do
  wait_until_processed "$app" "$timeout_seconds" || log_step "$app: records still missing after ${timeout_seconds}s"
done
for app in "${apps[@]}"; do
  wait_for_processing_rows "$app" "$ingestion_timeout_seconds" ||
    log_step "$app: not every blob is in Application Insights after ${ingestion_timeout_seconds}s"
done

markdown_row Run App Blobs 'Min (ms)' 'Median (ms)' 'p95 (ms)' 'Max (ms)' Logged Records Retries Duplicates
markdown_separator 11
for app in "${apps[@]}"; do
  rows_file="$(processing_rows_file "$app")"
  IFS=$'\t' read -r minimum median p95 maximum logged < <(latency_distribution "$rows_file")
  records="$(check_records "$app")"
  check_single_processing "$app"
  markdown_row "$RUN_ID" "$app" "$count" "$minimum" "$median" "$p95" "$maximum" "$logged/$count" "$records" \
    "$(retry_count "$rows_file")" "$(column_sum "$rows_file" 5)"
done
finish_scenario
