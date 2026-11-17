# The virtual network and every phase 1/2 subnet, plus private DNS for phase 2.
# The private endpoint object stays known during planning so endpoint counts do not depend on unknown subnet ids.

module "network" {
  source              = "./modules/network"
  name                = "vnet-${var.environment_name}-${local.token}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags
  address_space       = "10.60.0.0/16"
  subnets = {
    aks-nodes = {
      address_prefix = "10.60.0.0/22"
    }
    aks-api-server = {
      address_prefix = "10.60.4.0/28"
      delegation     = "Microsoft.ContainerService/managedClusters"
    }
    private-endpoints = {
      address_prefix = "10.60.5.0/24"
    }
    AzureBastionSubnet = {
      address_prefix = "10.60.6.0/26"
    }
    jumpbox = {
      address_prefix = "10.60.6.64/27"
    }
  }
  private_dns_zones = [
    "privatelink.azurecr.io",
    "privatelink.blob.core.windows.net",
    "privatelink.queue.core.windows.net",
    "privatelink.table.core.windows.net",
    "privatelink.servicebus.windows.net",
  ]
}

locals {
  network = {
    subnet_ids              = module.network.subnet_ids
    subnet_address_prefixes = module.network.subnet_address_prefixes
  }
  private_endpoint = var.private_networking ? {
    subnet_id            = module.network.subnet_ids["private-endpoints"]
    private_dns_zone_ids = module.network.private_dns_zone_ids
  } : null
}
