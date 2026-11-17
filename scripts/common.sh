#!/usr/bin/env bash
# Provides shared azd-setting and app-name lookups for the spike's test scripts.
# Storage operations use Entra authentication; no storage keys or storage connection strings.
set -euo pipefail

azd_value() {
  local name="$1"
  local value

  value="$(azd env get-value "$name")"
  if [[ -z "$value" ]]; then
    printf 'azd environment value %s is empty\n' "$name" >&2
    return 1
  fi
  printf '%s' "$value"
}

app_number() {
  case "$1" in
    blob-polling) printf '1' ;;
    queue-triggered) printf '2' ;;
    servicebus-triggered) printf '3' ;;
    *)
      printf 'unknown app: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

upload_account() {
  azd_value "UPLOADS_ACCOUNT_$(app_number "$1")"
}

host_account() {
  azd_value "HOST_ACCOUNT_$(app_number "$1")"
}

application_insights_resource_id() {
  local connection_string="$1"
  local instrumentation_key
  local resource_id

  if [[ "$connection_string" =~ InstrumentationKey=([^;]+) ]]; then
    instrumentation_key="${BASH_REMATCH[1]}"
  else
    printf 'APPLICATIONINSIGHTS_CONNECTION_STRING has no instrumentation key\n' >&2
    return 1
  fi

  resource_id="$(az monitor app-insights component list \
    --subscription "$(azd_value AZURE_SUBSCRIPTION_ID)" \
    --query "[?instrumentationKey=='${instrumentation_key}'].id | [0]" \
    --output tsv)"
  if [[ -z "$resource_id" || "$resource_id" == "None" ]]; then
    printf 'could not find the Application Insights component for this environment\n' >&2
    return 1
  fi
  printf '%s' "$resource_id"
}

processed_row_key() {
  local account="$1"
  local blob_name="$2"
  local etag="$3"

  printf '%s' "${account}/uploads/${blob_name}/${etag}/process" |
    sha256sum |
    cut -d ' ' -f 1
}

processed_record_count() {
  local account="$1"
  local app="$2"
  local row_key="$3"

  az storage entity query \
    --account-name "$account" \
    --table-name processed \
    --auth-mode login \
    --filter "PartitionKey eq '${app}' and RowKey eq '${row_key}'" \
    --query 'length(items)' \
    --output tsv
}
