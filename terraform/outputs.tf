output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "resource_group_name" {
  value = data.azurerm_resource_group.rg.name
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

output "alertmanager_identity_client_id" {
  value = azurerm_user_assigned_identity.alertmanager.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}
