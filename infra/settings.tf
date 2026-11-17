# Phase-dependent infrastructure settings (private networking, what Event Grid delivers into) and function scaling values.
# Environment values are supplied by azd so the same Terraform root can run both phases.

variable "private_networking" {
  description = "Enable private endpoints, Premium services, and a private AKS API server."
  type        = bool
  default     = false
}

variable "event_grid_destination_access" {
  description = "Phase 2 only (ignored in phase 1): public network access of what Event Grid delivers into, upload accounts 2 and 3 and the Service Bus namespace. enabled: all networks; trusted: selected networks with no rules, trusted services only; disabled: off."
  type        = string
  default     = "trusted"

  validation {
    condition     = contains(["enabled", "trusted", "disabled"], var.event_grid_destination_access)
    error_message = "event_grid_destination_access must be enabled, trusted or disabled."
  }
}

variable "aks_node_size" {
  description = "VM size for the AKS system node pool."
  type        = string
  default     = "Standard_D2als_v7"
}

variable "aks_authorized_ip_ranges" {
  description = "CIDR ranges allowed to reach the public AKS API server."
  type        = list(string)
  default     = []
}

variable "blob_polling_replicas" {
  description = "Fixed replica count for the polling Function app."
  type        = number
  default     = 2
}

variable "keda_min_replicas" {
  description = "Minimum replica count for queue-triggered Function apps."
  type        = number
  default     = 1
}

variable "keda_max_replicas" {
  description = "Maximum replica count for queue-triggered Function apps."
  type        = number
  default     = 10
}

variable "keda_messages_per_replica" {
  description = "Target messages per replica for KEDA scalers."
  type        = number
  default     = 5
}

locals {
  # Phase 1 keeps every Event Grid destination public, whatever the setting says.
  event_grid_destination_access = var.private_networking ? var.event_grid_destination_access : "enabled"
  # disabled is what Q5 (c) and Q6 (c) test: not claimed to work until an experiment shows Event Grid delivering.
  is_event_grid_destination_public_access_enabled = local.event_grid_destination_access != "disabled"
  event_grid_destination_default_action           = local.event_grid_destination_access == "enabled" ? "Allow" : "Deny"
}

output "EVENT_GRID_DESTINATION_ACCESS" {
  value = local.event_grid_destination_access
}

output "BLOB_POLLING_REPLICAS" {
  value = var.blob_polling_replicas
}

output "KEDA_MIN_REPLICAS" {
  value = var.keda_min_replicas
}

output "KEDA_MAX_REPLICAS" {
  value = var.keda_max_replicas
}

output "KEDA_MESSAGES_PER_REPLICA" {
  value = var.keda_messages_per_replica
}
