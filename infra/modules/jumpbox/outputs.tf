output "id" {
  value = azurerm_linux_virtual_machine.main.id
}

output "name" {
  value = azurerm_linux_virtual_machine.main.name
}

output "principal_id" {
  description = "The VM's system-assigned identity, for roles it needs on what it administers."
  value       = azurerm_linux_virtual_machine.main.identity[0].principal_id
}

output "network_security_group_id" {
  description = "Its subnet's network security group: an identity that writes the subnet needs to join it."
  value       = azurerm_network_security_group.main.id
}
