# Private access on demand: a jumpbox without a public IP in the "jumpbox" subnet, reached through an Azure Bastion
# (Standard, native client) that infra/scripts/bastion-up.sh creates for a working session, tagged delete-after, and a
# reaper function (functions/bastion-reaper, azd service "bastion-reaper") that deletes every host past its time, or
# without one, with the session's NAT Gateway (the jumpbox's outbound access), then deallocates the jumpbox. Terraform
# keeps only what is permanent: the jumpbox, the two public IPs and the reaper; the host and the NAT Gateway are not in
# the state, so that deleting them is no drift. infra/network.tf must declare the subnets "AzureBastionSubnet" (/26 or
# larger) and "jumpbox" (default_outbound_access = false), and set local.network.subnet_address_prefixes.

variable "jumpbox_size" {
  description = "VM size of the jumpbox (JUMPBOX_SIZE); one the subscription offers in the region (az vm list-skus)."
  type        = string
}

variable "jumpbox_login_object_ids" {
  description = "Entra object IDs, besides the deployer's, allowed to sign in to the jumpbox as administrators (JUMPBOX_LOGIN_OBJECT_IDS, comma-separated). Empty: the deployer only."
  type        = string
}

variable "reaper_deallocates_jumpbox" {
  description = "Whether the reaper deallocates the jumpbox when it ends a session (REAPER_DEALLOCATES_JUMPBOX)."
  type        = bool
}

locals {
  jumpbox_subnet_id = local.network.subnet_ids["jumpbox"]
  # /subscriptions/…/resourceGroups/…/providers/Microsoft.Network/virtualNetworks/<name>/subnets/jumpbox
  jumpbox_vnet_name = split("/", local.jumpbox_subnet_id)[8]
  jumpbox_login_object_ids = toset(concat(
    [data.azurerm_client_config.current.object_id],
    [for id in split(",", var.jumpbox_login_object_ids) : trimspace(id) if trimspace(id) != ""],
  ))
}

module "jumpbox" {
  source                    = "./modules/jumpbox"
  name                      = "jumpbox-${var.environment_name}"
  resource_group_id         = azurerm_resource_group.main.id
  resource_group_name       = azurerm_resource_group.main.name
  location                  = var.location
  tags                      = local.tags
  subnet_id                 = local.jumpbox_subnet_id
  ssh_source_address_prefix = local.network.subnet_address_prefixes["AzureBastionSubnet"]
  size                      = var.jumpbox_size
  login_object_ids          = local.jumpbox_login_object_ids
}

# The public IPs of the Bastion host and of the jumpbox's NAT Gateway: Standard and static, kept between sessions.
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  # Some tenants' policies add IP tags to new public IP addresses; they can only be set at creation, so a difference
  # would replace the address.
  lifecycle {
    ignore_changes = [ip_tags]

    precondition {
      condition     = contains(keys(local.network.subnet_ids), "AzureBastionSubnet") && contains(keys(local.network.subnet_ids), "jumpbox")
      error_message = "bastion-on-demand needs the subnets AzureBastionSubnet (/26 or larger) and jumpbox (default_outbound_access = false) in infra/network.tf."
    }
  }
}

resource "azurerm_public_ip" "bastion_nat" {
  name                = "pip-nat-jumpbox-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

# The reaper's two custom roles, each with only what it does: delete Bastion hosts and NAT Gateways and deallocate the
# jumpbox (the resource group); detach a NAT Gateway from the jumpbox subnet. A subnet write sends the subnet's links
# again, so the second role is also assigned on the subnet's network security group (join).
resource "azurerm_role_definition" "bastion_reaper" {
  name        = "Bastion session reaper (${var.environment_name}-${local.token})"
  description = "Deletes the Bastion hosts and NAT Gateways of ended sessions and deallocates the jumpbox."
  scope       = azurerm_resource_group.main.id

  permissions {
    actions = [
      "Microsoft.Network/bastionHosts/read",
      "Microsoft.Network/bastionHosts/delete",
      "Microsoft.Network/natGateways/read",
      "Microsoft.Network/natGateways/delete",
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/deallocate/action",
    ]
  }

  assignable_scopes = [azurerm_resource_group.main.id]
}

resource "azurerm_role_definition" "bastion_reaper_subnet" {
  name        = "Bastion session reaper, jumpbox subnet (${var.environment_name}-${local.token})"
  description = "Detaches a session's NAT Gateway from the jumpbox subnet, which keeps its network security group."
  scope       = azurerm_resource_group.main.id

  permissions {
    actions = [
      "Microsoft.Network/virtualNetworks/subnets/read",
      "Microsoft.Network/virtualNetworks/subnets/write",
      "Microsoft.Network/networkSecurityGroups/join/action",
    ]
  }

  assignable_scopes = [azurerm_resource_group.main.id]
}

module "bastion_reaper_storage" {
  source              = "./modules/storage-account"
  name                = "st${local.compact_name}reap${local.token}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags
}

module "bastion_reaper" {
  source                    = "./modules/function-app-flex"
  name                      = "func-reaper-${var.environment_name}-${local.token}"
  plan_name                 = "asp-reaper-${var.environment_name}"
  resource_group_id         = azurerm_resource_group.main.id
  resource_group_name       = azurerm_resource_group.main.name
  location                  = var.location
  tags                      = local.tags
  azd_service_name          = "bastion-reaper"
  storage_account_id        = module.bastion_reaper_storage.id
  storage_account_name      = module.bastion_reaper_storage.name
  storage_blob_endpoint     = module.bastion_reaper_storage.primary_blob_endpoint
  deployment_container_name = "reaper-package"
  runtime_name              = "dotnet-isolated"
  runtime_version           = "10.0"
  instance_memory_mb        = 512
  maximum_instance_count    = 1

  app_settings = {
    SUBSCRIPTION_ID     = var.subscription_id
    RESOURCE_GROUP_NAME = azurerm_resource_group.main.name
    JUMPBOX_NAME        = module.jumpbox.name
    DEALLOCATE_JUMPBOX  = tostring(var.reaper_deallocates_jumpbox)
  }

  application_insights_connection_string = module.monitoring.application_insights_connection_string
  role_assignments = {
    telemetry             = { scope = module.monitoring.application_insights_id, role = "Monitoring Metrics Publisher" }
    sessions              = { scope = azurerm_resource_group.main.id, role = azurerm_role_definition.bastion_reaper.name }
    subnet                = { scope = local.jumpbox_subnet_id, role = azurerm_role_definition.bastion_reaper_subnet.name }
    subnet_security_group = { scope = module.jumpbox.network_security_group_id, role = azurerm_role_definition.bastion_reaper_subnet.name }
  }
}

# The names the scripts and the reaper agree on; BASTION_NAME and NAT_GATEWAY_NAME are created by the scripts only.
output "JUMPBOX_NAME" { value = module.jumpbox.name }
output "JUMPBOX_ID" { value = module.jumpbox.id }
output "JUMPBOX_SUBNET_NAME" { value = "jumpbox" }
output "JUMPBOX_VNET_NAME" { value = local.jumpbox_vnet_name }
output "BASTION_NAME" { value = "bas-${var.environment_name}" }
output "BASTION_PUBLIC_IP_NAME" { value = azurerm_public_ip.bastion.name }
output "NAT_GATEWAY_NAME" { value = "ng-jumpbox-${var.environment_name}" }
output "NAT_PUBLIC_IP_NAME" { value = azurerm_public_ip.bastion_nat.name }
output "BASTION_REAPER_NAME" { value = module.bastion_reaper.name }
