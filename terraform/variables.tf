variable "resource_group_name" {
  type        = string
  description = "Existing resource group"
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
  description = "Node VM size"
  default     = "Standard_D2_v3"
}
