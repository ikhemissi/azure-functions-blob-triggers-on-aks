# Six Entra-only storage accounts hold uploads, Function host state, and Event Grid dead letters.
# The host-name prefix is shortened to keep its complete token within Azure's 24-character account limit.

locals {
  storage_account_names = {
    upload1 = "st${local.compact_name}up1${local.token}"
    upload2 = "st${local.compact_name}up2${local.token}"
    upload3 = "st${local.compact_name}up3${local.token}"
    host1   = "st${substr(local.compact_name, 0, 9)}host1${local.token}"
    host2   = "st${substr(local.compact_name, 0, 9)}host2${local.token}"
    host3   = "st${substr(local.compact_name, 0, 9)}host3${local.token}"
  }
}

module "storage_accounts" {
  for_each = local.storage_account_names
  source   = "./modules/storage-account"

  name                          = each.value
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.location
  tags                          = local.tags
  public_network_access_enabled = !var.private_networking
  private_endpoint_services     = ["blob", "queue", "table"]
  private_endpoint              = local.private_endpoint
}

resource "azurerm_storage_container" "uploads" {
  for_each = toset(["upload1", "upload2", "upload3"])

  name                  = "uploads"
  storage_account_id    = module.storage_accounts[each.key].id
  container_access_type = "private"
}

resource "azurerm_storage_queue" "blob_events" {
  name               = "blob-events"
  storage_account_id = module.storage_accounts["upload2"].id
}

resource "azurerm_storage_container" "eventgrid_deadletter" {
  for_each = toset(["upload2", "upload3"])

  name                  = "eventgrid-deadletter"
  storage_account_id    = module.storage_accounts[each.key].id
  container_access_type = "private"
}

# The idempotency records' tables, created through Resource Manager: azurerm_storage_table also sets the table's access
# policies through the data plane with the account's keys, which are disabled here.
resource "azapi_resource" "processed_table" {
  for_each = toset(["host1", "host2", "host3"])

  type      = "Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01"
  name      = "processed"
  parent_id = "${module.storage_accounts[each.key].id}/tableServices/default"
  body      = {}
}

output "UPLOADS_ACCOUNT_1" {
  value = module.storage_accounts["upload1"].name
}

output "UPLOADS_ACCOUNT_2" {
  value = module.storage_accounts["upload2"].name
}

output "UPLOADS_ACCOUNT_3" {
  value = module.storage_accounts["upload3"].name
}

output "HOST_ACCOUNT_1" {
  value = module.storage_accounts["host1"].name
}

output "HOST_ACCOUNT_2" {
  value = module.storage_accounts["host2"].name
}

output "HOST_ACCOUNT_3" {
  value = module.storage_accounts["host3"].name
}
