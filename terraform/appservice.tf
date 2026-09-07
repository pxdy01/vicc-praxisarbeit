resource "azurerm_service_plan" "main" {
  name                = "plan-${var.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
}

resource "azurerm_linux_web_app" "main" {
  name                = "app-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id

  # VNet-Integration: outbound-Traffic (u.a. zur DB) läuft über snet-app-integration
  virtual_network_subnet_id = azurerm_subnet.app_integration.id

  site_config {
    always_on = true

    application_stack {
      docker_image_name   = "${var.docker_image}:${var.docker_image_tag}"
      docker_registry_url = var.docker_registry_url
      docker_registry_username = var.docker_registry_username != "" ? var.docker_registry_username : null
      docker_registry_password = var.docker_registry_password != "" ? var.docker_registry_password : null
    }

    health_check_path                = "/health"
    health_check_eviction_time_in_min = 5
  }

  app_settings = {
    "WEBSITES_PORT"                       = "8000"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
    "DOCKER_ENABLE_CI"                    = "true"

    # DB-Verbindungsparameter für die Applikation (siehe app.py)
    "DB_HOST"     = azurerm_postgresql_flexible_server.main.fqdn
    "DB_PORT"     = "5432"
    "DB_NAME"     = azurerm_postgresql_flexible_server_database.app.name
    "DB_USER"     = var.postgres_admin_username
    "DB_PASSWORD" = var.postgres_admin_password
    "DB_SSLMODE"  = "require"
  }

  identity {
    type = "SystemAssigned"
  }

  logs {
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  depends_on = [azurerm_postgresql_flexible_server_database.app]
}
