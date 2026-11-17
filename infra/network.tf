# The virtual network and every phase 1/2 subnet, plus private DNS for phase 2 and its private endpoints' addresses.
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
  private_dns_zones = var.private_networking ? [
    "privatelink.azurecr.io",
    "privatelink.blob.core.windows.net",
    "privatelink.queue.core.windows.net",
    "privatelink.table.core.windows.net",
    "privatelink.servicebus.windows.net",
  ] : []
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

# The modules create their private endpoints (pe-<account>-<service>, pe-<registry>) without exposing their addresses:
# read back by name once the modules are applied.
data "azurerm_private_endpoint_connection" "module_endpoints" {
  for_each = toset(var.private_networking ? concat(
    flatten([
      for account in local.storage_accounts : [
        for service in account.private_endpoint_services : "pe-${account.name}-${service}"
      ]
    ]),
    ["pe-${local.container_registry_name}"],
  ) : [])

  name                = each.key
  resource_group_name = azurerm_resource_group.main.name

  depends_on = [module.storage_accounts, module.container_registry]
}

# Private endpoint name -> its first IP address (the registry's endpoint also has one for its data endpoint), to check
# that names resolve to them from inside the virtual network.
output "PRIVATE_ENDPOINT_IPS" {
  value = jsonencode(merge(
    {
      for name, endpoint in data.azurerm_private_endpoint_connection.module_endpoints :
      name => endpoint.private_service_connection[0].private_ip_address
    },
    {
      for endpoint in azurerm_private_endpoint.service_bus :
      endpoint.name => endpoint.private_service_connection[0].private_ip_address
    },
  ))
}
