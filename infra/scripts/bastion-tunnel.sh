#!/usr/bin/env bash
# Exposes the jumpbox's SSH port on localhost through the Bastion host, and writes an SSH configuration that signs in
# with your Entra identity: a short-lived certificate from `az ssh cert` (about an hour; run again to renew), which the
# jumpbox's Entra login accepts. Its files go to .azure/<environment>/ssh/ (git-ignored with .azure/). Then:
# ssh -F .azure/<environment>/ssh/config jumpbox, or VS Code Remote-SSH with that file.
#   infra/scripts/bastion-tunnel.sh [local port, default 2222]
set -euo pipefail
# shellcheck source=infra/scripts/bastion-settings.sh
source "$(dirname "${BASH_SOURCE[0]}")/bastion-settings.sh"

local_port="${1:-2222}"
ssh_folder="$(dirname "${BASH_SOURCE[0]}")/../../.azure/$ENVIRONMENT_NAME/ssh"
mkdir -p "$ssh_folder" && chmod 700 "$ssh_folder"
ssh_folder="$(cd "$ssh_folder" && pwd)"

step "Entra SSH certificate"
rm -f "$ssh_folder/id_entra" "$ssh_folder/id_entra.pub" "$ssh_folder/id_entra.pub-aadcert.pub"
az ssh cert --file "$ssh_folder/id_entra.pub-aadcert.pub" --public-key-file "$ssh_folder/id_entra.pub" 2>/dev/null \
  || { ssh-keygen -q -t rsa -b 4096 -N "" -f "$ssh_folder/id_entra" \
    && az ssh cert --file "$ssh_folder/id_entra.pub-aadcert.pub" --public-key-file "$ssh_folder/id_entra.pub"; }
# The certificate's principal is the Entra user name the jumpbox expects.
user_name="$(ssh-keygen -L -f "$ssh_folder/id_entra.pub-aadcert.pub" | sed -n '/Principals:/{n;p}' | xargs)"

cat >"$ssh_folder/config" <<CONFIG
Host jumpbox
  HostName 127.0.0.1
  Port $local_port
  User $user_name
  IdentityFile $ssh_folder/id_entra
  CertificateFile $ssh_folder/id_entra.pub-aadcert.pub
  # The tunnel's local end is localhost: the host key is the jumpbox's, kept apart from your known hosts.
  UserKnownHostsFile $ssh_folder/known_hosts
  StrictHostKeyChecking accept-new
CONFIG
echo "SSH configuration: $ssh_folder/config (host 'jumpbox')"

step "Tunnel on localhost:$local_port (Ctrl+C to close)"
exec az network bastion tunnel -g "$RESOURCE_GROUP" -n "$BASTION_NAME" --target-resource-id "$JUMPBOX_ID" \
  --resource-port 22 --port "$local_port"
