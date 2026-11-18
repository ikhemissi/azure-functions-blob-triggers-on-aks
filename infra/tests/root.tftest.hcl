# The whole root planned with mock providers: phase 1 (public), phase 2 with EVENT_GRID_DESTINATION_ACCESS trusted (the
# default) and disabled. Only what is known at plan time is asserted. The catalog modules' resources aren't reachable
# from here: which private endpoints they create is read from the names the root reads back, and the registry's SKU
# from the private endpoint it is given (the module picks Premium then).

mock_provider "azurerm" {
  # The cluster's Entra settings and the deployer's role assignment need UUIDs.
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000002"
      object_id       = "00000000-0000-0000-0000-000000000003"
    }
  }
}

mock_provider "azapi" {}
mock_provider "azuread" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "http" {}

variables {
  environment_name           = "spike-test"
  subscription_id            = "00000000-0000-0000-0000-000000000000"
  location                   = "francecentral"
  tags                       = ""
  aks_authorized_ip_ranges   = ["203.0.113.10/32"]
  jumpbox_size               = "Standard_D2als_v7"
  jumpbox_login_object_ids   = ""
  reaper_deallocates_jumpbox = true
}

run "public" {
  command = plan

  variables {
    private_networking = false
  }

  assert {
    condition     = length(module.network.private_dns_zone_ids) == 0 && local.private_endpoint == null
    error_message = "Phase 1 has no private DNS zones and gives the modules no private endpoint (registry Basic)."
  }
  assert {
    condition     = length(data.azurerm_private_endpoint_connection.module_endpoints) == 0 && length(azurerm_private_endpoint.service_bus) == 0
    error_message = "Phase 1 has no private endpoints."
  }
  assert {
    condition     = output.PRIVATE_ENDPOINT_IPS == "{}"
    error_message = "Phase 1 lists no private endpoint addresses."
  }
  assert {
    condition     = alltrue(values(local.is_storage_public_access_enabled))
    error_message = "Phase 1 keeps public access on for every storage account."
  }
  assert {
    condition     = length(azurerm_storage_account_network_rules.event_grid_destination) == 0
    error_message = "Phase 1 sets no storage network rules."
  }
  assert {
    condition     = azurerm_servicebus_namespace.main.sku == "Standard" && azurerm_servicebus_namespace.main.capacity == 0
    error_message = "Phase 1 uses Service Bus Standard."
  }
  assert {
    condition     = azurerm_servicebus_namespace.main.public_network_access_enabled && length(azapi_update_resource.service_bus_network_rule_set) == 0
    error_message = "Phase 1 keeps Service Bus public, with no network rule set."
  }
  assert {
    condition     = length(azapi_update_resource.registry_tasks_bypass) == 0
    error_message = "Phase 1 leaves the registry's bypass settings alone."
  }
  assert {
    condition     = azapi_update_resource.aks_api_server_access.body.properties.apiServerAccessProfile.enablePrivateCluster == false
    error_message = "Phase 1 keeps the API server public."
  }
  assert {
    condition     = azapi_update_resource.aks_api_server_access.body.properties.apiServerAccessProfile.authorizedIPRanges == tolist(["203.0.113.10/32"])
    error_message = "Phase 1 limits the API server to AKS_AUTHORIZED_IP_RANGES."
  }
  assert {
    condition     = length(azurerm_network_security_group.aks_nodes) == 0 && length(azurerm_network_security_group.private_endpoints) == 0
    error_message = "Phase 1 has no network security groups."
  }
  assert {
    condition     = output.EVENT_GRID_DESTINATION_ACCESS == "enabled"
    error_message = "EVENT_GRID_DESTINATION_ACCESS is ignored in phase 1: destinations stay public."
  }
}

run "private_trusted" {
  command = plan

  variables {
    private_networking = true
  }

  assert {
    condition     = length(module.network.private_dns_zone_ids) == 5
    error_message = "Phase 2 has a private DNS zone for blob, queue, table, Service Bus and the registry."
  }
  assert {
    condition = toset(keys(data.azurerm_private_endpoint_connection.module_endpoints)) == toset([
      "pe-${local.storage_accounts.upload1.name}-blob",
      "pe-${local.storage_accounts.upload1.name}-queue",
      "pe-${local.storage_accounts.upload2.name}-blob",
      "pe-${local.storage_accounts.upload2.name}-queue",
      "pe-${local.storage_accounts.upload3.name}-blob",
      "pe-${local.storage_accounts.host1.name}-blob",
      "pe-${local.storage_accounts.host1.name}-queue",
      "pe-${local.storage_accounts.host1.name}-table",
      "pe-${local.storage_accounts.host2.name}-blob",
      "pe-${local.storage_accounts.host2.name}-queue",
      "pe-${local.storage_accounts.host2.name}-table",
      "pe-${local.storage_accounts.host3.name}-blob",
      "pe-${local.storage_accounts.host3.name}-queue",
      "pe-${local.storage_accounts.host3.name}-table",
      "pe-${local.container_registry_name}",
    ])
    error_message = "Phase 2 has a private endpoint for each storage service its clients use, and for the registry."
  }
  assert {
    condition     = local.private_endpoint != null
    error_message = "Phase 2 gives the registry a private endpoint, so the module makes it Premium."
  }
  assert {
    condition     = length(azurerm_private_endpoint.service_bus) == 1
    error_message = "Phase 2 has a Service Bus private endpoint."
  }
  assert {
    condition = local.is_storage_public_access_enabled == {
      upload1 = false, upload2 = true, upload3 = true, host1 = false, host2 = false, host3 = false
    }
    error_message = "Phase 2 turns public access off on the host accounts and upload account 1; trusted keeps it on, restricted, where Event Grid delivers."
  }
  assert {
    condition = alltrue([
      for rules in azurerm_storage_account_network_rules.event_grid_destination :
      rules.default_action == "Deny" && rules.bypass == toset(["AzureServices"]) && rules.ip_rules == null && rules.virtual_network_subnet_ids == null
    ]) && length(azurerm_storage_account_network_rules.event_grid_destination) == 2
    error_message = "trusted: upload accounts 2 and 3 deny by default, with no IP or virtual network rules, and let trusted services in."
  }
  assert {
    condition = alltrue([
      for rules in azurerm_storage_account_network_rules.event_grid_destination : length(rules.private_link_access) == 1
    ])
    error_message = "Each Event Grid destination account has a resource instance rule for its system topic."
  }
  assert {
    condition     = azurerm_servicebus_namespace.main.sku == "Premium" && azurerm_servicebus_namespace.main.capacity == 1
    error_message = "Phase 2 uses Service Bus Premium with one messaging unit."
  }
  assert {
    condition     = azapi_update_resource.service_bus_network_rule_set[0].body.properties.trustedServiceAccessEnabled == true
    error_message = "Phase 2 lets trusted services (Event Grid) into the namespace."
  }
  assert {
    condition = (
      azapi_update_resource.service_bus_network_rule_set[0].body.properties.defaultAction == "Deny" &&
      azapi_update_resource.service_bus_network_rule_set[0].body.properties.publicNetworkAccess == "Enabled" &&
      azurerm_servicebus_namespace.main.public_network_access_enabled
    )
    error_message = "trusted: the namespace takes public traffic from selected networks only (none), default action Deny."
  }
  assert {
    condition     = azapi_update_resource.registry_tasks_bypass[0].body.properties.networkRuleBypassAllowedForTasks == true
    error_message = "Phase 2 lets ACR Tasks bypass the registry's network rules."
  }
  assert {
    condition     = azapi_update_resource.aks_api_server_access.body.properties.apiServerAccessProfile.enablePrivateCluster == true
    error_message = "Phase 2 makes the API server private."
  }
  assert {
    condition     = length(azapi_update_resource.aks_api_server_access.body.properties.apiServerAccessProfile.authorizedIPRanges) == 0
    error_message = "A private API server has no authorized IP ranges."
  }
  assert {
    condition     = length(azurerm_subnet_network_security_group_association.aks_nodes) == 1 && length(azurerm_subnet_network_security_group_association.private_endpoints) == 1
    error_message = "Phase 2 puts a network security group on aks-nodes and private-endpoints."
  }
  assert {
    condition     = output.EVENT_GRID_DESTINATION_ACCESS == "trusted"
    error_message = "trusted is the default in phase 2."
  }
}

run "private_disabled" {
  command = plan

  variables {
    private_networking            = true
    event_grid_destination_access = "disabled"
  }

  assert {
    condition     = !anytrue(values(local.is_storage_public_access_enabled))
    error_message = "disabled: no storage account takes public traffic."
  }
  assert {
    condition = (
      !azurerm_servicebus_namespace.main.public_network_access_enabled &&
      azapi_update_resource.service_bus_network_rule_set[0].body.properties.publicNetworkAccess == "Disabled" &&
      azapi_update_resource.service_bus_network_rule_set[0].body.properties.trustedServiceAccessEnabled == true
    )
    error_message = "disabled: the namespace takes no public traffic, the trusted-services bypass stays set."
  }
  assert {
    condition = alltrue([
      for rules in azurerm_storage_account_network_rules.event_grid_destination : rules.bypass == toset(["AzureServices"])
    ])
    error_message = "disabled: the storage bypass stays set."
  }
}

run "invalid_event_grid_destination_access" {
  command = plan

  variables {
    event_grid_destination_access = "private"
  }

  expect_failures = [var.event_grid_destination_access]
}
