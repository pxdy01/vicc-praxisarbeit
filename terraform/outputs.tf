output "resource_group_name" {
  description = "Name der Resource Group."
  value       = azurerm_resource_group.main.name
}

output "app_service_name" {
  description = "Name der Web App."
  value       = azurerm_linux_web_app.main.name
}

output "app_service_url" {
  description = "Öffentliche URL der Applikation."
  value       = "https://${azurerm_linux_web_app.main.default_hostname}"
}

output "postgres_fqdn" {
  description = "FQDN des PostgreSQL-Servers (nur im VNet auflösbar)."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "database_name" {
  description = "Name der Applikationsdatenbank."
  value       = azurerm_postgresql_flexible_server_database.app.name
}

output "container_image" {
  description = "Bereitgestelltes Container-Image."
  value       = local.image
}
