# What the deployer needs to run the tests and scenarios (scripts/): upload blobs, put and peek messages, read the
# processing records, with their own Entra identity (no keys). Scoped to the spike's accounts and namespace only.

locals {
  tester_roles = {
    upload1_blobs        = { scope = module.storage_accounts["upload1"].id, role = "Storage Blob Data Contributor" }
    upload2_blobs        = { scope = module.storage_accounts["upload2"].id, role = "Storage Blob Data Contributor" }
    upload3_blobs        = { scope = module.storage_accounts["upload3"].id, role = "Storage Blob Data Contributor" }
    upload2_queues       = { scope = module.storage_accounts["upload2"].id, role = "Storage Queue Data Contributor" }
    host1_tables         = { scope = module.storage_accounts["host1"].id, role = "Storage Table Data Reader" }
    host2_tables         = { scope = module.storage_accounts["host2"].id, role = "Storage Table Data Reader" }
    host3_tables         = { scope = module.storage_accounts["host3"].id, role = "Storage Table Data Reader" }
    service_bus_sender   = { scope = azurerm_servicebus_namespace.main.id, role = "Azure Service Bus Data Sender" }
    service_bus_receiver = { scope = azurerm_servicebus_namespace.main.id, role = "Azure Service Bus Data Receiver" }
  }
}

resource "azurerm_role_assignment" "tester" {
  for_each             = local.tester_roles
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = data.azurerm_client_config.current.object_id
}
