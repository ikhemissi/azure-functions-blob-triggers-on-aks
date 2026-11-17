# The image registry switches from Basic to Premium when private networking is enabled.
# Its pull identity is also configured as the AKS kubelet identity.

locals {
  container_registry_name = "cr${local.compact_name}${local.token}"
}

module "container_registry" {
  source                        = "./modules/container-registry"
  name                          = local.container_registry_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.location
  tags                          = local.tags
  public_network_access_enabled = !var.private_networking
  private_endpoint              = local.private_endpoint
}

# Phase 2: azd builds the images with ACR Tasks (remoteBuild), which reach a registry without public access only as a
# trusted service with the Tasks bypass on (https://learn.microsoft.com/azure/container-registry/allow-access-trusted-services,
# https://learn.microsoft.com/azure/container-registry/manage-network-bypass-policy-for-tasks). The module leaves both
# settings at the provider's defaults (AzureServices, and Tasks bypass off), hence this resource. Until the module takes
# network_rule_bypass_for_tasks_enabled, every phase 2 plan shows the module's registry setting the Tasks bypass back
# to false, and this resource setting it to true after it in the same apply. To verify (Q11): azd deploy builds and
# pushes the images with public access off.
resource "azapi_update_resource" "registry_tasks_bypass" {
  count = var.private_networking ? 1 : 0

  type        = "Microsoft.ContainerRegistry/registries@2025-11-01"
  resource_id = module.container_registry.id
  body = {
    properties = {
      networkRuleBypassOptions         = "AzureServices"
      networkRuleBypassAllowedForTasks = true
    }
  }
}

output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  value = module.container_registry.login_server
}
