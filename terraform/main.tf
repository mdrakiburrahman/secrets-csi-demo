# ---------------------------------------------------------------------------------------------------------------------
# AZURE RESOURCE GROUP
# ---------------------------------------------------------------------------------------------------------------------
resource "azurerm_resource_group" "k8s_csi" {
  name     = var.resource_group_name
  location = var.resource_group_location
  tags     = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# AKS - SIMPLE
# ---------------------------------------------------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_name
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name
  dns_prefix          = "akscsi"

  default_node_pool {
    name                = "agentpool"
    node_count          = 1
    vm_size             = "Standard_DS3_v2"
    type                = "VirtualMachineScaleSets"
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 2

  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [
      # Ignore changes to nodes because we have autoscale enabled
      default_node_pool[0].node_count
    ]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# AKV
# ---------------------------------------------------------------------------------------------------------------------
data "azurerm_client_config" "current" {}

resource "random_string" "lower" {
  length  = 5
  upper   = false
  lower   = true
  number  = false
  special = false
}

resource "azurerm_key_vault" "akv" {
  name                        = "csiakv${random_string.lower.result}"
  location                    = var.resource_group_location
  resource_group_name         = var.resource_group_name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name = "standard"

  // SP
  access_policy {
    tenant_id      = data.azurerm_client_config.current.tenant_id
    object_id      = data.azurerm_client_config.current.object_id
    application_id = data.azurerm_client_config.current.client_id

    key_permissions = [
      "Backup", "Create", "Decrypt", "Delete", "Encrypt", "Get", "Import", "List", "Purge", "Recover", "Restore", "Sign", "UnwrapKey", "Update", "Verify", "WrapKey"
    ]

    secret_permissions = [
      "Backup", "Delete", "Get", "List", "Purge", "Recover", "Restore", "Set",
    ]

    storage_permissions = [
      "Backup", "Delete", "DeleteSAS", "Get", "GetSAS", "List", "ListSAS", "Purge", "Recover", "RegenerateKey", "Restore", "SetSAS", "Update",
    ]
  }
  // User
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = var.akv_admin_oid

    key_permissions = [
      "Backup", "Create", "Decrypt", "Delete", "Encrypt", "Get", "Import", "List", "Purge", "Recover", "Restore", "Sign", "UnwrapKey", "Update", "Verify", "WrapKey"
    ]

    secret_permissions = [
      "Backup", "Delete", "Get", "List", "Purge", "Recover", "Restore", "Set",
    ]

    storage_permissions = [
      "Backup", "Delete", "DeleteSAS", "Get", "GetSAS", "List", "ListSAS", "Purge", "Recover", "RegenerateKey", "Restore", "SetSAS", "Update",
    ]
  }

  tags = var.tags
}
