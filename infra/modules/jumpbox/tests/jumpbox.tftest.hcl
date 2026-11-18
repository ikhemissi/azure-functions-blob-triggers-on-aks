# SSH from the Bastion subnet only, no public IP, Entra sign-in roles for each object ID, no password.

mock_provider "azurerm" {}

mock_provider "azapi" {
  mock_resource "azapi_resource_action" {
    defaults = {
      output = { publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0 generated" }
    }
  }
}

variables {
  name                      = "jumpbox-test"
  resource_group_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test"
  resource_group_name       = "rg-test"
  location                  = "francecentral"
  subnet_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/jumpbox"
  ssh_source_address_prefix = "10.40.0.0/26"
  size                      = "Standard_D2als_v7"
  login_object_ids          = ["00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000b"]
}

run "ssh_from_the_bastion_subnet_only" {
  command = plan

  assert {
    condition = anytrue([for rule in azurerm_network_security_group.main.security_rule :
    rule.access == "Allow" && rule.destination_port_range == "22" && rule.source_address_prefix == "10.40.0.0/26"])
    error_message = "SSH must be allowed from the Bastion subnet."
  }

  assert {
    condition = anytrue([for rule in azurerm_network_security_group.main.security_rule :
    rule.access == "Deny" && rule.source_address_prefix == "*" && rule.direction == "Inbound"])
    error_message = "Every other inbound connection must be denied."
  }
}

run "private_vm_signed_in_with_entra_id" {
  command = plan

  assert {
    condition     = azurerm_network_interface.main.ip_configuration[0].public_ip_address_id == null
    error_message = "The jumpbox must have no public IP."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.main.disable_password_authentication
    error_message = "No password sign-in."
  }

  assert {
    condition     = length(azurerm_role_assignment.login) == 2
    error_message = "One Virtual Machine Administrator Login per object ID."
  }
}
