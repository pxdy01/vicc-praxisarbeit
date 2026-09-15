resource "azurerm_service_plan" "main" {
  name                = "asp-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = var.tags
}

resource "azurerm_linux_web_app" "main" {
  name                = "app-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true

  # Regionale VNet-Integration -> Zugriff auf die private DB
  virtual_network_subnet_id = azurerm_subnet.app.id

  site_config {
    always_on              = true
    ftps_state             = "Disabled"
    minimum_tls_version    = "1.2"
    http2_enabled          = true
    vnet_route_all_enabled = true

    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2

    application_stack {
      docker_image_name        = local.image
      docker_registry_url      = var.docker_registry_url
      docker_registry_username = local.use_registry_credentials ? var.docker_registry_username : null
      docker_registry_password = local.use_registry_credentials ? var.docker_registry_password : null
    }
  }

  app_settings = {
    WEBSITES_PORT                       = "8000"
    PORT                                = "8000"
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"

    DB_HOST     = azurerm_postgresql_flexible_server.main.fqdn
    DB_PORT     = "5432"
    DB_NAME     = azurerm_postgresql_flexible_server_database.app.name
    DB_USER     = var.postgres_admin_username
    DB_PASSWORD = var.postgres_admin_password
    DB_SSLMODE  = "require"
  }

  # Container-Logs (stdout/stderr) -> az webapp log tail
  logs {
    detailed_error_messages = true
    failed_request_tracing  = false

    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  tags = var.tags
}
