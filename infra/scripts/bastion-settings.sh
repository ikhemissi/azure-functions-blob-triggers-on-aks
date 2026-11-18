#!/usr/bin/env bash
# Settings shared by the session scripts (sourced, not run): the names Terraform gave the session's parts, read from the
# selected azd environment, and the tags every part created by a script carries.

# shellcheck disable=SC2034  # the names below are used by the scripts that source this file
azd_value() { azd env get-value "$1"; }

RESOURCE_GROUP="$(azd_value AZURE_RESOURCE_GROUP)"
LOCATION="$(azd_value AZURE_LOCATION)"
ENVIRONMENT_NAME="$(azd_value AZURE_ENV_NAME)"
VNET_NAME="$(azd_value JUMPBOX_VNET_NAME)"
JUMPBOX_NAME="$(azd_value JUMPBOX_NAME)"
JUMPBOX_ID="$(azd_value JUMPBOX_ID)"
JUMPBOX_SUBNET_NAME="$(azd_value JUMPBOX_SUBNET_NAME)"
BASTION_NAME="$(azd_value BASTION_NAME)"
BASTION_PUBLIC_IP_NAME="$(azd_value BASTION_PUBLIC_IP_NAME)"
NAT_GATEWAY_NAME="$(azd_value NAT_GATEWAY_NAME)"
NAT_PUBLIC_IP_NAME="$(azd_value NAT_PUBLIC_IP_NAME)"
DELETE_AFTER_TAG="delete-after"

# session_tags <delete-after time>: the tenant's tags (RESOURCE_TAGS, "key=value,key=value"), the azd environment's,
# and the time the session's parts must be deleted, as arguments for `az … --tags`.
session_tags() {
  local tags=("azd-env-name=$ENVIRONMENT_NAME" "$DELETE_AFTER_TAG=$1") pair
  local extra_tags
  extra_tags="$(azd_value RESOURCE_TAGS 2>/dev/null || true)"
  IFS=',' read -ra pairs <<<"$extra_tags"
  for pair in "${pairs[@]}"; do
    pair="$(echo "$pair" | xargs)"
    [[ -n "$pair" ]] && tags+=("$pair")
  done
  printf '%s\n' "${tags[@]}"
}

# utc_in_hours <hours> [from, ISO 8601]: the UTC time that many hours later, in the tag's format.
utc_in_hours() {
  date -u -d "${2:-now} + $1 hours" +%Y-%m-%dT%H:%M:%SZ
}

step() { echo "== $*"; }
