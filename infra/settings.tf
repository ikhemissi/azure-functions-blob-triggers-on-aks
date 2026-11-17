# Phase-dependent infrastructure settings and function scaling values.
# Environment values are supplied by azd so the same Terraform root can run both phases.

variable "private_networking" {
  description = "Enable private endpoints, Premium services, and a private AKS API server."
  type        = bool
  default     = false
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
