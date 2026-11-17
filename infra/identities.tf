# Each Function app uses its own identity for host storage, trigger data, telemetry, and scaling.
# Both the app service account and KEDA operator are federated to that same workload identity.

locals {
  app_identities = {
    blob-polling = {
      name            = "id-blob-polling-${var.environment_name}"
      host            = "host1"
      service_account = "blob-polling"
    }
    queue-triggered = {
      name            = "id-queue-triggered-${var.environment_name}"
      host            = "host2"
      service_account = "queue-triggered"
    }
    servicebus-triggered = {
      name            = "id-servicebus-triggered-${var.environment_name}"
      host            = "host3"
      service_account = "servicebus-triggered"
    }
  }

  app_role_assignments = merge(
    {
      for assignment in flatten([
        for app, config in local.app_identities : [
          {
            key   = "${app}-host-blob"
            app   = app
            role  = "Storage Blob Data Owner"
            scope = module.storage_accounts[config.host].id
          },
          {
            key   = "${app}-host-queue"
            app   = app
            role  = "Storage Queue Data Contributor"
            scope = module.storage_accounts[config.host].id
          },
          {
            key   = "${app}-host-table"
            app   = app
            role  = "Storage Table Data Contributor"
            scope = module.storage_accounts[config.host].id
          },
          {
            key   = "${app}-monitoring"
            app   = app
            role  = "Monitoring Metrics Publisher"
            scope = module.monitoring.application_insights_id
          }
        ]
      ]) : assignment.key => assignment
    },
    {
      "blob-polling-upload-blob" = {
        app   = "blob-polling"
        role  = "Storage Blob Data Owner"
        scope = module.storage_accounts["upload1"].id
      }
      "blob-polling-upload-queue" = {
        app   = "blob-polling"
        role  = "Storage Queue Data Contributor"
        scope = module.storage_accounts["upload1"].id
      }
      "queue-triggered-upload-queue" = {
        app   = "queue-triggered"
        role  = "Storage Queue Data Contributor"
        scope = module.storage_accounts["upload2"].id
      }
      "queue-triggered-upload-blob" = {
        app   = "queue-triggered"
        role  = "Storage Blob Data Reader"
        scope = module.storage_accounts["upload2"].id
      }
      "servicebus-triggered-upload-blob" = {
        app   = "servicebus-triggered"
        role  = "Storage Blob Data Reader"
        scope = module.storage_accounts["upload3"].id
      }
      "servicebus-triggered-queue" = {
        app   = "servicebus-triggered"
        role  = "Azure Service Bus Data Receiver"
        scope = azurerm_servicebus_queue.blob_events.id
      }
    }
  )
}

resource "azurerm_user_assigned_identity" "app" {
  for_each = local.app_identities

  name                = each.value.name
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "app" {
  for_each = merge([
    for app, config in local.app_identities : {
      "${app}-service-account" = {
        app     = app
        subject = "system:serviceaccount:functions:${config.service_account}"
      }
      "${app}-keda-operator" = {
        app     = app
        subject = "system:serviceaccount:kube-system:keda-operator"
      }
    }
  ]...)

  name                = each.key
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.app[each.value.app].id
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = each.value.subject
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "app" {
  for_each = local.app_role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.app[each.value.app].principal_id
  principal_type       = "ServicePrincipal"
}

output "BLOB_POLLING_CLIENT_ID" {
  value = azurerm_user_assigned_identity.app["blob-polling"].client_id
}

output "QUEUE_TRIGGERED_CLIENT_ID" {
  value = azurerm_user_assigned_identity.app["queue-triggered"].client_id
}

output "SERVICEBUS_TRIGGERED_CLIENT_ID" {
  value = azurerm_user_assigned_identity.app["servicebus-triggered"].client_id
}
