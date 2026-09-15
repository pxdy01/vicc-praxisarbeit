# Suffix für global eindeutige Namen (PostgreSQL-Server, Web App)
resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  name                     = "${var.project_name}-${random_string.suffix.result}"
  image                    = "${var.docker_image}:${var.docker_image_tag}"
  use_registry_credentials = var.docker_registry_username != "" && var.docker_registry_password != ""
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = var.tags
}
