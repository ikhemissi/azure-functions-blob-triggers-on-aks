# Event Grid routes uploads from accounts 2 and 3 to the queue-based triggers.
# Each system topic uses its own identity for delivery and dead-letter writes.

resource "azurerm_eventgrid_system_topic" "storage_queue" {
  name                   = "egst-up2-${var.environment_name}"
  location               = var.location
  resource_group_name    = azurerm_resource_group.main.name
  source_arm_resource_id = module.storage_accounts["upload2"].id
  topic_type             = "Microsoft.Storage.StorageAccounts"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_eventgrid_system_topic" "service_bus" {
  name                   = "egst-up3-${var.environment_name}"
  location               = var.location
  resource_group_name    = azurerm_resource_group.main.name
  source_arm_resource_id = module.storage_accounts["upload3"].id
  topic_type             = "Microsoft.Storage.StorageAccounts"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "eventgrid_storage_queue_sender" {
  scope                = azurerm_storage_queue.blob_events.id
  role_definition_name = "Storage Queue Data Message Sender"
  principal_id         = azurerm_eventgrid_system_topic.storage_queue.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "eventgrid_storage_deadletter_writer" {
  # Event Grid's check of its dead-letter identity refused this role on the container (Q8); on the account it passes.
  scope                = module.storage_accounts["upload2"].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_eventgrid_system_topic.storage_queue.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "eventgrid_service_bus_sender" {
  scope                = azurerm_servicebus_queue.blob_events.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.service_bus.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "eventgrid_service_bus_deadletter_writer" {
  # Event Grid's check of its dead-letter identity refused this role on the container (Q8); on the account it passes.
  scope                = module.storage_accounts["upload3"].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_eventgrid_system_topic.service_bus.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Event Grid checks its identity's access to the destination and the dead-letter container when a subscription is
# created; new role assignments take a minute or two to apply, so the subscriptions wait for them.
resource "time_sleep" "eventgrid_roles" {
  create_duration = "120s"

  depends_on = [
    azurerm_role_assignment.eventgrid_storage_queue_sender,
    azurerm_role_assignment.eventgrid_storage_deadletter_writer,
    azurerm_role_assignment.eventgrid_service_bus_sender,
    azurerm_role_assignment.eventgrid_service_bus_deadletter_writer,
  ]
}

resource "azurerm_eventgrid_system_topic_event_subscription" "storage_queue" {
  name                = "to-storage-queue"
  resource_group_name = azurerm_resource_group.main.name
  system_topic        = azurerm_eventgrid_system_topic.storage_queue.name
  included_event_types = [
    "Microsoft.Storage.BlobCreated",
  ]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/uploads/"
    case_sensitive      = false
  }

  storage_queue_endpoint {
    storage_account_id = module.storage_accounts["upload2"].id
    queue_name         = azurerm_storage_queue.blob_events.name
  }

  storage_blob_dead_letter_destination {
    storage_account_id          = module.storage_accounts["upload2"].id
    storage_blob_container_name = azurerm_storage_container.eventgrid_deadletter["upload2"].name
  }

  delivery_identity {
    type = "SystemAssigned"
  }

  dead_letter_identity {
    type = "SystemAssigned"
  }

  depends_on = [time_sleep.eventgrid_roles]
}

resource "azurerm_eventgrid_system_topic_event_subscription" "service_bus" {
  name                = "to-service-bus"
  resource_group_name = azurerm_resource_group.main.name
  system_topic        = azurerm_eventgrid_system_topic.service_bus.name
  included_event_types = [
    "Microsoft.Storage.BlobCreated",
  ]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/uploads/"
    case_sensitive      = false
  }

  service_bus_queue_endpoint_id = azurerm_servicebus_queue.blob_events.id

  storage_blob_dead_letter_destination {
    storage_account_id          = module.storage_accounts["upload3"].id
    storage_blob_container_name = azurerm_storage_container.eventgrid_deadletter["upload3"].name
  }

  delivery_identity {
    type = "SystemAssigned"
  }

  dead_letter_identity {
    type = "SystemAssigned"
  }

  depends_on = [time_sleep.eventgrid_roles]
}
