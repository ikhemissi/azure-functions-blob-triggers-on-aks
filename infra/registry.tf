# The image registry switches from Basic to Premium when private networking is enabled.
# Its pull identity is also configured as the AKS kubelet identity.

module "container_registry" {
  source                        = "./modules/container-registry"
  name                          = "cr${local.compact_name}${local.token}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.location
  tags                          = local.tags
  public_network_access_enabled = !var.private_networking
  private_endpoint              = local.private_endpoint
}


output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  value = module.container_registry.login_server
}
