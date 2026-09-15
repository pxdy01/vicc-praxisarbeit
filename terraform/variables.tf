# ------------------------------------------------------------------ #
# Allgemein
# ------------------------------------------------------------------ #
variable "subscription_id" {
  description = "Azure-Subscription-ID (az account show --query id -o tsv)."
  type        = string
}

variable "location" {
  description = "Azure-Region."
  type        = string
  default     = "switzerlandnorth"
}

variable "project_name" {
  description = "Präfix für alle Ressourcennamen (Kleinbuchstaben, Ziffern, Bindestrich)."
  type        = string
  default     = "vicc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.project_name))
    error_message = "project_name: 2-15 Zeichen, a-z, 0-9, '-', beginnt mit Buchstabe."
  }
}

variable "tags" {
  description = "Tags für alle Ressourcen."
  type        = map(string)
  default     = {
    project = "vicc-praxisarbeit"
    managed = "terraform"
  }
}

# ------------------------------------------------------------------ #
# Netzwerk
# ------------------------------------------------------------------ #
variable "vnet_address_space" {
  description = "Adressraum des VNet."
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_app_prefix" {
  description = "Subnetz für App-Service-VNet-Integration (delegiert an Microsoft.Web/serverFarms)."
  type        = string
  default     = "10.20.1.0/24"
}

variable "subnet_db_prefix" {
  description = "Subnetz für PostgreSQL Flexible Server (delegiert an Microsoft.DBforPostgreSQL/flexibleServers)."
  type        = string
  default     = "10.20.2.0/24"
}

# ------------------------------------------------------------------ #
# PostgreSQL
# ------------------------------------------------------------------ #
variable "postgres_version" {
  description = "PostgreSQL-Hauptversion."
  type        = string
  default     = "16"
}

variable "postgres_sku_name" {
  description = "SKU des Flexible Servers (Burstable)."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Speichergrösse in MB."
  type        = number
  default     = 32768
}

variable "postgres_admin_username" {
  description = "Admin-Login des Flexible Servers."
  type        = string
  default     = "vicc_admin"

  validation {
    condition     = !contains(["admin", "administrator", "root", "postgres", "azure_superuser", "guest", "public"], lower(var.postgres_admin_username))
    error_message = "Dieser Benutzername ist bei Azure PostgreSQL reserviert."
  }
}

variable "postgres_admin_password" {
  description = "Admin-Passwort des Flexible Servers. Nur via terraform.tfvars oder TF_VAR_postgres_admin_password setzen."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.postgres_admin_password) >= 12 &&
      length(var.postgres_admin_password) <= 128 &&
      length(regexall("[A-Z]", var.postgres_admin_password)) > 0 &&
      length(regexall("[a-z]", var.postgres_admin_password)) > 0 &&
      length(regexall("[0-9]", var.postgres_admin_password)) > 0
    )
    error_message = "Passwort: 12-128 Zeichen, mind. je ein Gross-, Kleinbuchstabe und eine Ziffer."
  }
}

variable "database_name" {
  description = "Name der Applikationsdatenbank."
  type        = string
  default     = "tasks"
}

# ------------------------------------------------------------------ #
# App Service / Container
# ------------------------------------------------------------------ #
variable "app_service_sku" {
  description = "SKU des Linux App Service Plans (B1 = kleinste SKU mit VNet-Integration und Always On)."
  type        = string
  default     = "B1"
}

variable "docker_image" {
  description = "Image-Name auf Docker Hub (ohne Tag)."
  type        = string
  default     = "patrikzauggipso/vicc-api"
}

variable "docker_image_tag" {
  description = "Image-Tag."
  type        = string
  default     = "2.0.0"
}

variable "docker_registry_url" {
  description = "Registry-URL (Docker Hub)."
  type        = string
  default     = "https://index.docker.io"
}

variable "docker_registry_username" {
  description = "Docker-Hub-Benutzer. Leer lassen bei öffentlichem Image."
  type        = string
  default     = ""
}

variable "docker_registry_password" {
  description = "Docker-Hub-Access-Token (Read-only). Leer lassen bei öffentlichem Image."
  type        = string
  default     = ""
  sensitive   = true
}
