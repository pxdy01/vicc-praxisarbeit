resource "azurerm_postgresql_flexible_server" "main" {
  name                = "psql-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  version                       = var.postgres_version
  administrator_login          = var.postgres_admin_username
  administrator_password       = var.postgres_admin_password
  storage_mb                    = var.postgres_storage_mb
  sku_name                       = var.postgres_sku_name
  zone                            = "1"

  # Kein öffentlicher Netzwerkzugriff: Der Server ist nur über das
  # delegierte Subnet (VNet-Integration) erreichbar.
  public_network_access_enabled = false
  delegated_subnet_id            = azurerm_subnet.postgres.id
  private_dns_zone_id            = azurerm_private_dns_zone.postgres.id

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    ignore_changes = [zone] # Azure kann die Zone bei Kapazitätsengpässen intern anpassen
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.postgres_database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# Zufälliges Suffix für global eindeutige Ressourcennamen
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}
