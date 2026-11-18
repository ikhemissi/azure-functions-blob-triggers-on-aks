#!/usr/bin/env bash
# Moves the end of the open session: its delete-after tag, on the Bastion host and the NAT Gateway.
#   infra/scripts/bastion-extend.sh <hours>            later than the current end (or than now, if it has passed)
#   infra/scripts/bastion-extend.sh --until <time>     to that UTC time (ISO 8601)
set -euo pipefail
# shellcheck source=infra/scripts/bastion-settings.sh
source "$(dirname "${BASH_SOURCE[0]}")/bastion-settings.sh"

bastion_id="$(az network bastion show -g "$RESOURCE_GROUP" -n "$BASTION_NAME" --query id -o tsv)"
nat_gateway_id="$(az network nat gateway show -g "$RESOURCE_GROUP" -n "$NAT_GATEWAY_NAME" --query id -o tsv)"

if [[ "${1:-}" == "--until" ]]; then
  delete_after="${2:?usage: bastion-extend.sh --until <UTC time>}"
else
  hours="${1:?usage: bastion-extend.sh <hours>}"
  current="$(az tag list --resource-id "$bastion_id" --query "properties.tags.\"$DELETE_AFTER_TAG\"" -o tsv)"
  # Count from now when the tag is missing or already past.
  if [[ -z "$current" ]] || (($(date -u -d "$current" +%s) < $(date +%s))); then current="now"; fi
  delete_after="$(utc_in_hours "$hours" "$current")"
fi

for id in "$bastion_id" "$nat_gateway_id"; do
  az tag update --resource-id "$id" --operation Merge --tags "$DELETE_AFTER_TAG=$delete_after" -o none
done
echo "The session now ends at $delete_after."
