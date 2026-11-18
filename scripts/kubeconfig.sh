#!/usr/bin/env bash
# Points kubectl at this azd environment's AKS cluster, never at another one: every script and hook step that calls
# kubectl sources this file. It writes the cluster's credentials to .azure/<env>/kubeconfig (git-ignored), converted
# to Azure CLI sign-in (local accounts are off), and exports KUBECONFIG to that file.
# Inside an azd hook, AZURE_ENV_NAME selects the environment azd runs for; elsewhere, azd's default environment.
# Needs az (signed in), azd and kubelogin (`az aks install-cli` installs it).
set -euo pipefail

kubeconfig_setting() {
  local name="$1"
  local value

  # In a hook, `azd ... -e <env>` may run for an environment that is not the default one.
  if [[ -n "${AZURE_ENV_NAME:-}" ]]; then
    value="$(azd env get-value "$name" --environment "$AZURE_ENV_NAME")"
  else
    value="$(azd env get-value "$name")"
  fi
  if [[ -z "$value" ]]; then
    printf 'azd environment value %s is empty\n' "$name" >&2
    return 1
  fi
  printf '%s' "$value"
}

write_environment_kubeconfig() {
  local repository_root
  local environment_name
  local resource_group
  local cluster_name
  local kubeconfig_file

  if ! command -v kubelogin >/dev/null; then
    echo "kubelogin is missing: install it with 'az aks install-cli'" >&2
    return 1
  fi
  repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  environment_name="$(kubeconfig_setting AZURE_ENV_NAME)"
  resource_group="$(kubeconfig_setting AZURE_RESOURCE_GROUP)"
  cluster_name="$(kubeconfig_setting AZURE_AKS_CLUSTER_NAME)"
  kubeconfig_file="$repository_root/.azure/$environment_name/kubeconfig"

  mkdir -p "$(dirname -- "$kubeconfig_file")"
  az aks get-credentials \
    --resource-group "$resource_group" \
    --name "$cluster_name" \
    --file "$kubeconfig_file" \
    --overwrite-existing \
    --only-show-errors
  kubelogin convert-kubeconfig --login azurecli --kubeconfig "$kubeconfig_file"
  chmod 600 "$kubeconfig_file"
  export KUBECONFIG="$kubeconfig_file"
}

write_environment_kubeconfig
