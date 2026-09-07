variable "subscription_id" {
  description = "Azure Subscription ID, in der die Ressourcen erstellt werden."
  type        = string
}

variable "prefix" {
  description = "Namenspräfix für alle Ressourcen (muss global-eindeutige Namen unterstützen)."
  type        = string
  default     = "vicc"
}

variable "location" {
  description = "Azure Region."
  type        = string
  default     = "switzerlandnorth"
}

# ---------------------------------------------------------------------------
# Container / Docker Hub
# ---------------------------------------------------------------------------

variable "docker_image" {
  description = "Docker-Hub-Repository der Applikation, z.B. 'meinuser/vicc-api'."
  type        = string
}

variable "docker_image_tag" {
  description = "Tag des zu deployenden Images."
  type        = string
  default     = "latest"
}

variable "docker_registry_url" {
  description = "Registry-URL. Für öffentliche Docker-Hub-Images unverändert lassen."
  type        = string
  default     = "https://index.docker.io"
}

variable "docker_registry_username" {
  description = "Optional: Benutzername für ein privates Docker-Hub-Repository (Read-only Token empfohlen)."
  type        = string
  default     = ""
}

variable "docker_registry_password" {
  description = "Optional: Passwort/Access-Token für ein privates Docker-Hub-Repository."
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# App Service
# ---------------------------------------------------------------------------

variable "app_service_sku" {
  description = "SKU des Linux App Service Plan (z.B. B1, P0v3)."
  type        = string
  default     = "B1"
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

variable "postgres_admin_username" {
  description = "Administrator-Login für Azure Database for PostgreSQL Flexible Server."
  type        = string
  default     = "pgadmin"
}

variable "postgres_admin_password" {
  description = "Administrator-Passwort für Azure Database for PostgreSQL Flexible Server."
  type        = string
  sensitive   = true
}

variable "postgres_sku_name" {
  description = "SKU des Flexible Server (z.B. 'B_Standard_B1ms' für Burstable, günstig für Praxisarbeit)."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Speichergrösse in MB."
  type        = number
  default     = 32768
}

variable "postgres_version" {
  description = "PostgreSQL Major Version."
  type        = string
  default     = "16"
}

variable "postgres_database_name" {
  description = "Name der initial angelegten Datenbank."
  type        = string
  default     = "appdb"
}
