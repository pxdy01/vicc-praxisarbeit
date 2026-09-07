output "app_service_url" {
  description = "URL, unter der die Applikation im Browser erreichbar ist."
  value       = "https://${azurerm_linux_web_app.main.default_hostname}"
}

output "app_service_name" {
  value = azurerm_linux_web_app.main.name
}

output "postgres_server_fqdn" {
  description = "Privater FQDN des PostgreSQL Flexible Servers (nur innerhalb des VNet auflösbar)."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_database_name" {
  value = azurerm_postgresql_flexible_server_database.app.name
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}
