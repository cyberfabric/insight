variable "m365_azure_tenant_id" {
  type    = string
  default = ""
}

variable "m365_client_id" {
  type    = string
  default = ""
}

variable "m365_client_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "m365_start_date" {
  type    = string
  default = "2026-01-01"
}

resource "airbyte_source_custom" "m365" {
  count        = var.m365_client_id != "" ? 1 : 0
  name         = "m365-${var.tenant_id}"
  workspace_id = var.workspace_id

  source_definition_id = "64a2f99c-542f-4af8-9a6f-355f1217b436"

  configuration = jsonencode({
    tenant_id        = var.tenant_id
    azure_tenant_id  = var.m365_azure_tenant_id
    client_id        = var.m365_client_id
    client_secret    = var.m365_client_secret
    start_date       = var.m365_start_date
  })
}

resource "airbyte_connection" "m365_to_clickhouse" {
  count            = var.m365_client_id != "" ? 1 : 0
  name             = "m365-to-clickhouse-${var.tenant_id}"
  source_id        = airbyte_source_custom.m365[0].source_id
  destination_id   = airbyte_destination_clickhouse.main.destination_id
  namespace_format = "bronze_${var.tenant_id}"
  status           = "active"
}
