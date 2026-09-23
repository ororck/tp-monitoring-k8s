variable "location" {
  type        = string
  description = "The Azure region where resources will be created"
  default     = "westeurope"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group"
}

variable "aks_cluster_name" {
  type        = string
  description = "Name of the AKS cluster"
}

variable "key_vault_name" {
  type        = string
  description = "Name of the Key Vault"
}

variable "aks_node_count" {
  type        = number
  description = "Number of nodes in the default node pool"
  default     = 2
}

variable "aks_vm_size" {
  type        = string
  description = "VM size for the AKS nodes"
  default     = "Standard_B2s"
}
