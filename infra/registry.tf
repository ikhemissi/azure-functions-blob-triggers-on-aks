# The image registry switches from Basic to Premium when private networking is enabled.
# Its pull identity is also configured as the AKS kubelet identity.
# In phase 2 the registry takes no public traffic, so images are built inside the virtual network (on the jumpbox) and
# pushed through the private endpoint: azd's remote build (an ACR Tasks quick run) is refused by a registry whose public
# access is off, with or without the Tasks network bypass (docs/experiments/05-making-phase-2-run.md).

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

output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  value = module.container_registry.login_server
}
