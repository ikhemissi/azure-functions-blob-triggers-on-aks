# A Linux jumpbox without a public IP: SSH only from the Bastion subnet, sign-in with Entra ID (the AADSSHLoginForLinux
# extension, installed once the VM has outbound access), an administrator key whose private half is kept nowhere.

resource "azurerm_network_security_group" "main" {
  name                = "nsg-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "AllowSshFromBastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.ssh_source_address_prefix
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "22"
  }

  # Everything else inbound, the rest of the virtual network included.
  security_rule {
    name                       = "DenyAllOtherInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = var.subnet_id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_network_interface" "main" {
  name                = "nic-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "private"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# Azure requires an administrator key on a Linux VM even when people sign in with Entra ID. Azure generates the pair;
# only the public key is kept (the private key is in no state or output), so the account can't be used.
resource "azapi_resource" "admin_key" {
  type      = "Microsoft.Compute/sshPublicKeys@2024-07-01"
  name      = "sshkey-${var.name}"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags
  body      = {}
}

resource "azapi_resource_action" "admin_key_pair" {
  type                   = "Microsoft.Compute/sshPublicKeys@2024-07-01"
  resource_id            = azapi_resource.admin_key.id
  action                 = "generateKeyPair"
  method                 = "POST"
  response_export_values = ["publicKey"]
}

resource "azurerm_linux_virtual_machine" "main" {
  name                  = "vm-${var.name}"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.size
  network_interface_ids = [azurerm_network_interface.main.id]
  # The v6 and later sizes have NVMe disk controllers only.
  disk_controller_type            = "NVMe"
  admin_username                  = "azureadmin"
  disable_password_authentication = true
  tags                            = var.tags

  admin_ssh_key {
    username   = "azureadmin"
    public_key = azapi_resource_action.admin_key_pair.output.publicKey
  }

  # The Entra SSH login extension needs the VM's own identity.
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Managed boot diagnostics: the serial console and boot logs without a storage account.
  boot_diagnostics {}
}

resource "azurerm_role_assignment" "login" {
  for_each             = var.login_object_ids
  scope                = azurerm_linux_virtual_machine.main.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value
}
