resource "airbyte_destination_clickhouse" "main" {
  name         = "clickhouse-${var.tenant_id}"
  workspace_id = var.workspace_id

  configuration = {
    host     = var.clickhouse_host
    port     = var.clickhouse_port
    database = "bronze_${var.tenant_id}"
    username = var.clickhouse_user
    password = var.clickhouse_password
    ssl      = false
  }
}

variable "clickhouse_host" {
  type    = string
  default = "host.docker.internal"
}

variable "clickhouse_port" {
  type    = number
  default = 8123
}

variable "clickhouse_user" {
  type    = string
  default = "default"
}

variable "clickhouse_password" {
  type      = string
  sensitive = true
  default   = ""
}
