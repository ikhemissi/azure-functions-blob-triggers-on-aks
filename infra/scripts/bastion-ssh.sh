#!/usr/bin/env bash
# Opens SSH to the jumpbox through the Bastion host, signed in with your Entra identity (no SSH key).
set -euo pipefail
# shellcheck source=infra/scripts/bastion-settings.sh
source "$(dirname "${BASH_SOURCE[0]}")/bastion-settings.sh"

exec az network bastion ssh -g "$RESOURCE_GROUP" -n "$BASTION_NAME" --target-resource-id "$JUMPBOX_ID" --auth-type AAD
