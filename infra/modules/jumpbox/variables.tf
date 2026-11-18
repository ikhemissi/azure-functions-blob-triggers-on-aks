variable "name" {
  description = "Base name: the VM is vm-<name>, its network security group nsg-<name>, its NIC nic-<name>."
  type        = string
}

variable "resource_group_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "subnet_id" {
  description = "The jumpbox's subnet, given this module's network security group; private (no default outbound access) is best."
  type        = string
}

variable "ssh_source_address_prefix" {
  description = "The only address range allowed to reach SSH: the AzureBastionSubnet's."
  type        = string
}

variable "size" {
  description = "A VM size the subscription offers in the region (az vm list-skus); v6 and later sizes need the NVMe controller set here."
  type        = string
}

variable "login_object_ids" {
  description = "Entra object IDs allowed to sign in as administrators (Virtual Machine Administrator Login)."
  type        = set(string)
}
