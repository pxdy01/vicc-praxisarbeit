terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.30"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State liegt lokal (terraform.tfstate, via .gitignore ausgeschlossen).
}

provider "azurerm" {
  features {
    resource_group {
      # destroy soll auch dann durchlaufen, wenn Azure implizit Ressourcen angelegt hat
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}
