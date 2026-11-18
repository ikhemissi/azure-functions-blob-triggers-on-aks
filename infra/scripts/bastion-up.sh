#!/usr/bin/env bash
# Starts a session: the jumpbox's NAT Gateway (its outbound access), the jumpbox itself, the Bastion host (Standard,
# native client), all tagged to be deleted after the given number of hours (default 8); while the host is being
# created, the jumpbox gets its Entra SSH login and tools. Every step can run again: during a session, or after an
# interrupted start, the script completes what is missing and moves the session's end.
#   infra/scripts/bastion-up.sh [hours]
set -euo pipefail
# shellcheck source=infra/scripts/bastion-settings.sh
source "$(dirname "${BASH_SOURCE[0]}")/bastion-settings.sh"

hours="${1:-8}"
delete_after="$(utc_in_hours "$hours")"
mapfile -t tags < <(session_tags "$delete_after")

step "NAT Gateway for the jumpbox's outbound access"
az network nat gateway create -g "$RESOURCE_GROUP" -n "$NAT_GATEWAY_NAME" -l "$LOCATION" \
  --public-ip-addresses "$NAT_PUBLIC_IP_NAME" --tags "${tags[@]}" -o none
az network vnet subnet update -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$JUMPBOX_SUBNET_NAME" \
  --nat-gateway "$NAT_GATEWAY_NAME" -o none

step "Bastion host (Standard, native client)"
bastion_started=$(date +%s)
if az network bastion show -g "$RESOURCE_GROUP" -n "$BASTION_NAME" -o none 2>/dev/null; then
  echo "already there (its end is moved below)"
  is_new_bastion=false
else
  az network bastion create -g "$RESOURCE_GROUP" -n "$BASTION_NAME" -l "$LOCATION" --vnet-name "$VNET_NAME" \
    --public-ip-address "$BASTION_PUBLIC_IP_NAME" --sku Standard --enable-tunneling true \
    --tags "${tags[@]}" --no-wait -o none
  echo "being created in the background"
  is_new_bastion=true
fi

step "Jumpbox"
az vm start -g "$RESOURCE_GROUP" -n "$JUMPBOX_NAME" -o none

step "Entra SSH login on the jumpbox (needs its outbound access)"
az vm extension set -g "$RESOURCE_GROUP" --vm-name "$JUMPBOX_NAME" \
  --publisher Microsoft.Azure.ActiveDirectory --name AADSSHLoginForLinux -o none

step "Tools on the jumpbox (installed once)"
az vm run-command invoke -g "$RESOURCE_GROUP" -n "$JUMPBOX_NAME" --command-id RunShellScript \
  --scripts @"$(dirname "${BASH_SOURCE[0]}")/jumpbox-install-tools.sh" --query "value[0].message" -o tsv \
  | sed -n '/\[stdout\]/,/\[stderr\]/p' | grep -v '^\['

step "Waiting for the Bastion host"
az network bastion wait -g "$RESOURCE_GROUP" -n "$BASTION_NAME" --created
if [[ "$is_new_bastion" == true ]]; then
  echo "Bastion host ready in $(($(date +%s) - bastion_started)) s."
else
  # The host was there already: give it, like the NAT Gateway above, this run's end.
  "$(dirname "${BASH_SOURCE[0]}")/bastion-extend.sh" --until "$delete_after" >/dev/null
fi
echo "The session ends at $delete_after (infra/scripts/bastion-extend.sh <hours> to move it)."
echo "Connect: infra/scripts/bastion-ssh.sh (terminal), infra/scripts/bastion-tunnel.sh (VS Code, ssh forwarding)."
