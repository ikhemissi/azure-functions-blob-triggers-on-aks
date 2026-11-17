#!/usr/bin/env bash
# Uploads one blob per app and verifies its idempotency row appears in the processed table.
# Waits up to five minutes for all three records and exits nonzero if any is missing.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

apps=(blob-polling queue-triggered servicebus-triggered)
declare -A accounts host_accounts blob_names row_keys
temporary_file="$(mktemp)"
trap 'rm -f "$temporary_file"' EXIT

for app in "${apps[@]}"; do
  accounts["$app"]="$(upload_account "$app")"
  host_accounts["$app"]="$(host_account "$app")"
  blob_names["$app"]="$(date -u +'%Y%m%dT%H%M%S%N')Z-${app}-integration.txt"
  printf 'integration test blob for %s\n' "$app" >"$temporary_file"
  az storage blob upload \
    --account-name "${accounts[$app]}" \
    --container-name uploads \
    --name "${blob_names[$app]}" \
    --file "$temporary_file" \
    --auth-mode login \
    --output none
  uploaded_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\t%s\t%s\n' "$app" "${blob_names[$app]}" "$uploaded_at"
  etag="$(az storage blob show \
    --account-name "${accounts[$app]}" \
    --container-name uploads \
    --name "${blob_names[$app]}" \
    --auth-mode login \
    --query properties.etag \
    --output tsv)"
  row_keys["$app"]="$(processed_row_key "${accounts[$app]}" "${blob_names[$app]}" "$etag")"
done

for ((attempt = 1; attempt <= 60; attempt++)); do
  all_records_found=true
  for app in "${apps[@]}"; do
    record_count="$(processed_record_count \
      "${host_accounts[$app]}" "$app" "${row_keys[$app]}")"
    if [[ "$record_count" -gt 1 ]]; then
      printf 'expected exactly one processed row for %s/%s; found %s\n' \
        "$app" "${blob_names[$app]}" "$record_count" >&2
      exit 1
    fi
    if [[ "$record_count" != 1 ]]; then
      all_records_found=false
    fi
  done
  if [[ "$all_records_found" == true ]]; then
    echo "Each test blob has exactly one processing row."
    exit 0
  fi
  sleep 5
done

for app in "${apps[@]}"; do
  record_count="$(processed_record_count \
    "${host_accounts[$app]}" "$app" "${row_keys[$app]}")"
  if [[ "$record_count" != 1 ]]; then
    printf 'expected exactly one processed row for %s/%s; found %s\n' \
      "$app" "${blob_names[$app]}" "$record_count" >&2
  fi
done
exit 1
