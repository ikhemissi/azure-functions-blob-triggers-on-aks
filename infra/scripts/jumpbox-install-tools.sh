#!/usr/bin/env bash
# Installs the jumpbox's tools once, as root (run by `az vm run-command` from infra/scripts/bastion-up.sh, during a session,
# when the NAT Gateway gives the jumpbox outbound access): the Azure CLI from Microsoft's package repository, kubectl
# and kubelogin (Entra sign-in to AKS) with the Azure CLI, and azd with its installer.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# run-command starts the script without a home directory, which azd needs.
export HOME=/root

if command -v az >/dev/null && command -v azd >/dev/null && command -v kubectl >/dev/null && command -v kubelogin >/dev/null; then
  echo "Tools already installed: az $(az version --query '"azure-cli"' -o tsv), azd $(azd version | awk '{print $3}'), kubectl $(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  exit 0
fi

apt-get update -q
apt-get install -y -q ca-certificates curl gnupg jq unzip

# Azure CLI, from Microsoft's package repository.
curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash

# kubectl and kubelogin, latest stable releases.
az aks install-cli --install-location /usr/local/bin/kubectl --kubelogin-install-location /usr/local/bin/kubelogin

# Azure Developer CLI, with its installer.
curl -fsSL https://aka.ms/install-azd.sh | bash

echo "Installed: az $(az version --query '"azure-cli"' -o tsv), azd $(azd version | awk '{print $3}'), kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
