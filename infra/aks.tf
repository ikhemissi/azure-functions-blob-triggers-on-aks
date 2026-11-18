# The cluster runs the three Function apps with Entra RBAC and Workload Identity.
# AzureRM 4.81 marks private_cluster_enabled ForceNew, though AKS supports toggling it in place with VNet Integration:
# the cluster resource ignores it after creation, and azapi_update_resource.aks_api_server_access switches it.

locals {
  # Pods get addresses from this range (Azure CNI Overlay); the nodes' network security group lets it in.
  aks_pod_cidr = "192.168.0.0/16"
}

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-aks-control-plane-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-aks-kubelet-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "control_plane_network" {
  scope                = module.network.virtual_network_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = module.container_registry.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "control_plane_kubelet_operator" {
  scope                = azurerm_user_assigned_identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster" "main" {
  name                      = "aks-${var.environment_name}-${local.token}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.main.name
  dns_prefix                = "aks-${var.environment_name}"
  kubernetes_version        = "1.37"
  sku_tier                  = "Free"
  private_cluster_enabled   = var.private_networking
  local_account_disabled    = true
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                        = "system"
    vm_size                     = var.aks_node_size
    node_count                  = 2
    type                        = "VirtualMachineScaleSets"
    vnet_subnet_id              = local.network.subnet_ids["aks-nodes"]
    temporary_name_for_rotation = "nodeswap"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = local.network.subnet_ids["aks-api-server"]
    authorized_ip_ranges                = var.private_networking ? null : var.aks_authorized_ip_ranges
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = local.aks_pod_cidr
    service_cidr        = "10.62.0.0/16"
    dns_service_ip      = "10.62.0.10"
    load_balancer_sku   = "standard"
  }

  workload_autoscaler_profile {
    keda_enabled = true
  }

  tags = local.tags

  lifecycle {
    # Both are set at creation only; afterwards azapi_update_resource.aks_api_server_access owns them.
    ignore_changes = [
      private_cluster_enabled,
      api_server_access_profile[0].authorized_ip_ranges,
      # Some tenants' policies turn on Microsoft Defender for the cluster; without this, every plan would turn it off.
      microsoft_defender,
    ]

    precondition {
      condition = var.private_networking || (
        length(var.aks_authorized_ip_ranges) > 0 &&
        !contains(var.aks_authorized_ip_ranges, "0.0.0.0/32")
      )
      error_message = "Set AKS_AUTHORIZED_IP_RANGES to the deployer's public CIDR range before creating a public AKS API server."
    }
  }

  depends_on = [
    azurerm_role_assignment.control_plane_network,
    azurerm_role_assignment.control_plane_kubelet_operator,
  ]
}

# Switches the API server between public (limited to AKS_AUTHORIZED_IP_RANGES) and private without replacing the
# cluster, which API Server VNet Integration supports after creation
# (https://learn.microsoft.com/azure/aks/api-server-vnet-integration, "Enable or disable private cluster mode on an
# existing cluster with API Server VNet Integration"). Both in one request: a private cluster takes no authorized IP
# ranges. To verify (Q11): the switch in both directions, and the private DNS zone AKS creates for the API server.
resource "azapi_update_resource" "aks_api_server_access" {
  type        = "Microsoft.ContainerService/managedClusters@2025-10-01"
  resource_id = azurerm_kubernetes_cluster.main.id
  body = {
    properties = {
      apiServerAccessProfile = {
        enablePrivateCluster = var.private_networking
        authorizedIPRanges   = var.private_networking ? [] : var.aks_authorized_ip_ranges
      }
    }
  }
}

resource "azurerm_role_assignment" "aks_deployer_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

output "AKS_NAME" {
  value = azurerm_kubernetes_cluster.main.name
}

output "AZURE_AKS_CLUSTER_NAME" {
  value = azurerm_kubernetes_cluster.main.name
}
