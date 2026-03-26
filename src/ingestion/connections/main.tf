terraform {
  required_providers {
    airbyte = {
      source  = "airbytehq/airbyte"
      version = ">= 0.6.0"
    }
  }
}

provider "airbyte" {
  server_url = var.airbyte_url
  username   = var.airbyte_username
  password   = var.airbyte_password
}

variable "airbyte_url" {
  type    = string
  default = "http://localhost:8000/api/public/v1"
}

variable "airbyte_username" {
  type    = string
  default = ""
}

variable "airbyte_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "tenant_id" {
  type = string
}

variable "workspace_id" {
  type    = string
  default = ""
}
