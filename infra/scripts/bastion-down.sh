#!/usr/bin/env bash
# Ends the session now: deletes the Bastion host and the NAT Gateway (detached from the jumpbox's subnet first), then
# deallocates the jumpbox, which keeps only its disk.
#   infra/scripts/bastion-down.sh [--keep-jumpbox]
set -euo pipefail
# shellcheck source=infra/scripts/bastion-settings.sh
source "$(dirname "${BASH_SOURCE[0]}")/bastion-settings.sh"

step "Bastion host"
if az network bastion show -g "$RESOURCE_GROUP" -n "$BASTION_NAME" -o none 2>/dev/null; then
  started=$(date +%s)
  # --yes: without it, the command asks for confirmation and, without a terminal, cancels.
  az network bastion delete -g "$RESOURCE_GROUP" -n "$BASTION_NAME" --yes -o none
  echo "deleted in $(($(date +%s) - started)) s"
else
  echo "none"
fi

step "NAT Gateway"
if az network nat gateway show -g "$RESOURCE_GROUP" -n "$NAT_GATEWAY_NAME" -o none 2>/dev/null; then
  az network vnet subnet update -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$JUMPBOX_SUBNET_NAME" \
    --remove natGateway -o none
  az network nat gateway delete -g "$RESOURCE_GROUP" -n "$NAT_GATEWAY_NAME" -o none
  echo "deleted"
else
  echo "none"
fi

if [[ "${1:-}" == "--keep-jumpbox" ]]; then
  echo "The jumpbox keeps running."
else
  step "Jumpbox (deallocated)"
  az vm deallocate -g "$RESOURCE_GROUP" -n "$JUMPBOX_NAME" -o none
fi
