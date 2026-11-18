# Phase 2: network security groups on the nodes' and the private endpoints' subnets, letting in what each needs and
# denying the rest from the internet. AzureBastionSubnet and jumpbox get theirs with the Bastion block.

resource "azurerm_network_security_group" "aks_nodes" {
  count               = var.private_networking ? 1 : 0
  name                = "nsg-aks-nodes-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags

  # Azure CNI Overlay doesn't encapsulate pod traffic, and the pod range is outside the virtual network's address space:
  # node to node, node to pod and pod to pod traffic must be allowed explicitly
  # (https://learn.microsoft.com/azure/aks/azure-cni-overlay, "Network security groups").
  security_rule {
    name                         = "allow-cluster-inbound"
    priority                     = 100
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_range       = "*"
    source_address_prefixes      = [local.network.subnet_address_prefixes["aks-nodes"], local.aks_pod_cidr]
    destination_address_prefixes = [local.network.subnet_address_prefixes["aks-nodes"], local.aks_pod_cidr]
  }

  # API Server VNet Integration: the API server reaches the kubelets, webhooks and pods from its own subnet.
  security_rule {
    name                         = "allow-api-server-inbound"
    priority                     = 110
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_range       = "*"
    source_address_prefix        = local.network.subnet_address_prefixes["aks-api-server"]
    destination_address_prefixes = [local.network.subnet_address_prefixes["aks-nodes"], local.aks_pod_cidr]
  }

  security_rule {
    name                       = "allow-azure-load-balancer-inbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# The network module leaves private endpoint network policies off on the subnet (the provider's default), so these
# rules don't filter traffic to the private endpoints until the module turns them on; to verify before relying on them.
resource "azurerm_network_security_group" "private_endpoints" {
  count               = var.private_networking ? 1 : 0
  name                = "nsg-private-endpoints-${var.environment_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.tags

  # Storage and the registry (HTTPS) and Service Bus (AMQP, and HTTPS for management), from the nodes and the jumpbox;
  # pods reach them through their node's address.
  security_rule {
    name                       = "allow-https-from-virtual-network"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = local.network.subnet_address_prefixes["private-endpoints"]
  }

  security_rule {
    name                       = "allow-amqp-from-virtual-network"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5671-5672"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = local.network.subnet_address_prefixes["private-endpoints"]
  }

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  count                     = var.private_networking ? 1 : 0
  subnet_id                 = local.network.subnet_ids["aks-nodes"]
  network_security_group_id = azurerm_network_security_group.aks_nodes[0].id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  count                     = var.private_networking ? 1 : 0
  subnet_id                 = local.network.subnet_ids["private-endpoints"]
  network_security_group_id = azurerm_network_security_group.private_endpoints[0].id
}
