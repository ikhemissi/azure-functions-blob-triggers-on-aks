# The trigger queue uses Entra authentication only and the Standard/Premium tier follows the network phase.
# Its receiver identity is scoped to the queue rather than the namespace.

resource "azurerm_servicebus_namespace" "main" {
  name                          = "sb-${var.environment_name}-${local.token}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.main.name
  sku                           = var.private_networking ? "Premium" : "Standard"
  local_auth_enabled            = false
  public_network_access_enabled = !var.private_networking
  minimum_tls_version           = "1.2"
  tags                          = local.tags
}

resource "azurerm_servicebus_queue" "blob_events" {
  name                                 = "blob-events"
  namespace_id                         = azurerm_servicebus_namespace.main.id
  max_delivery_count                   = 5
  dead_lettering_on_message_expiration = true
}

resource "azurerm_private_endpoint" "service_bus" {
  count               = var.private_networking ? 1 : 0
  name                = "pe-${azurerm_servicebus_namespace.main.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  subnet_id           = local.private_endpoint.subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = azurerm_servicebus_namespace.main.name
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [local.private_endpoint.private_dns_zone_ids["privatelink.servicebus.windows.net"]]
  }
}

output "SERVICE_BUS_NAMESPACE" {
  value = azurerm_servicebus_namespace.main.name
}
