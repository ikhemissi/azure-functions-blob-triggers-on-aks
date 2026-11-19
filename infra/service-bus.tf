# The trigger queue uses Entra authentication only and the Standard/Premium tier follows the network phase.
# Its receiver identity is scoped to the queue rather than the namespace.

resource "azurerm_servicebus_namespace" "main" {
  name                = "sb-${var.environment_name}-${local.token}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  # Private endpoints and trusted services need Premium. The provider can't move a namespace to or from Premium: changing
  # PRIVATE_NETWORKING replaces the namespace, and with it the queue, its role assignments and the Event Grid subscription.
  sku                           = var.private_networking ? "Premium" : "Standard"
  capacity                      = var.private_networking ? 1 : 0
  premium_messaging_partitions  = var.private_networking ? 1 : 0
  local_auth_enabled            = false
  public_network_access_enabled = local.is_service_bus_public_access_enabled
  minimum_tls_version           = "1.2"
  tags                          = local.tags
}

# Phase 2: Event Grid delivers into the namespace as a trusted service (Q6, EVENT_GRID_DESTINATION_ACCESS). Service Bus
# refuses default action Deny without IP or virtual network rules while public access is on ("InvalidNetworkRuleSetUpdate":
# to restrict data-plane requests to private links, disable public access), so for "trusted" and "disabled" the
# namespace takes no public traffic and keeps the trusted-services bypass; the two modes differ for the storage accounts
# only (docs/experiments/07-event-grid-destination-access.md).
locals {
  is_service_bus_public_access_enabled = local.event_grid_destination_access == "enabled"
}

resource "azapi_update_resource" "service_bus_network_rule_set" {
  count = var.private_networking ? 1 : 0

  type        = "Microsoft.ServiceBus/namespaces/networkRuleSets@2024-01-01"
  resource_id = "${azurerm_servicebus_namespace.main.id}/networkRuleSets/default"
  body = {
    properties = {
      defaultAction               = local.event_grid_destination_default_action
      publicNetworkAccess         = local.is_service_bus_public_access_enabled ? "Enabled" : "Disabled"
      trustedServiceAccessEnabled = true
      ipRules                     = []
      virtualNetworkRules         = []
    }
  }
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
