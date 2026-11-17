#!/usr/bin/env bash
# Uploads uniquely named test blobs to the selected app's uploads container.
# Prints each blob name and its UTC upload time; requires an active azd environment.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "usage: $0 <blob-polling|queue-triggered|servicebus-triggered|all> [count]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
target="$1"
count="${2:-1}"
[[ "$count" =~ ^[1-9][0-9]*$ ]] || usage

if [[ "$target" == "all" ]]; then
  apps=(blob-polling queue-triggered servicebus-triggered)
else
  app_number "$target" >/dev/null
  apps=("$target")
fi

temporary_file="$(mktemp)"
trap 'rm -f "$temporary_file"' EXIT

for app in "${apps[@]}"; do
  account="$(upload_account "$app")"
  for ((index = 1; index <= count; index++)); do
    timestamp="$(date -u +'%Y%m%dT%H%M%S%N')Z"
    blob_name="${timestamp}-${app}-${index}.txt"
    printf 'test blob for %s uploaded at %s\n' "$app" "$timestamp" >"$temporary_file"
    az storage blob upload \
      --account-name "$account" \
      --container-name uploads \
      --name "$blob_name" \
      --file "$temporary_file" \
      --auth-mode login \
      --output none
    uploaded_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\t%s\t%s\n' "$app" "$blob_name" "$uploaded_at"
  done
done
