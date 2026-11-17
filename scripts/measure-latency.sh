#!/usr/bin/env bash
# Queries Application Insights for completed processing records matching a blob-name prefix.
# Prints the blob, processing pod, latency, duplicate invocations, and retries.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

[[ $# -eq 2 ]] || {
  echo "usage: $0 <blob-polling|queue-triggered|servicebus-triggered> <blob-prefix>" >&2
  exit 2
}
app="$1"
app_number "$app" >/dev/null
prefix="$2"
[[ "$prefix" =~ ^[a-zA-Z0-9_-]+$ ]] || {
  echo "blob-prefix may contain only letters, numbers, underscores, and hyphens" >&2
  exit 2
}

connection_string="$(azd_value APPLICATIONINSIGHTS_CONNECTION_STRING)"
application_id="$(application_insights_resource_id "$connection_string")"
query=$(cat <<KUSTO
traces
| extend blobName = tostring(customDimensions["blobName"])
| extend podName = tostring(customDimensions["podName"])
| extend latencyMs = tolong(customDimensions["latencyMs"])
| extend isDuplicate = tobool(customDimensions["duplicate"])
| where tostring(customDimensions["app"]) == "$app"
| where startswith(blobName, "$prefix")
| where isnotnull(latencyMs)
| summarize pod = take_any(podName),
            latencyMs = max(latencyMs),
            duplicates = dcountif(operation_Id, isDuplicate),
            attempts = dcount(operation_Id) by blobName
| extend retries = max_of(attempts - 1, 0)
| project blobName, pod, latencyMs, duplicates, retries
| order by blobName asc
KUSTO
)

az monitor app-insights query \
  --ids "$application_id" \
  --analytics-query "$query" \
  --output table
