
# ---------------------------------------------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES
# Define these secrets as environment variables
# ---------------------------------------------------------------------------------------------------------------------

variable "SPN_SUBSCRIPTION_ID" {
  description = "Azure Subscription ID"
  type        = string
}

variable "SPN_CLIENT_ID" {
  description = "Azure service principal name"
  type        = string
}

variable "SPN_CLIENT_SECRET" {
  description = "Azure service principal password"
  type        = string
}

variable "SPN_TENANT_ID" {
  description = "Azure tenant ID"
  type        = string
}

# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED PARAMETERS
# You must provide a value for each of these parameters.
# ---------------------------------------------------------------------------------------------------------------------

# TBD

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These parameters have reasonable defaults.
# ---------------------------------------------------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Deployment RG name"
  type        = string
  default     = "raki-csi-test-rg"
}

variable "aks_name" {
  description = "Azure Kubernetes Service Name"
  type        = string
  default     = "aks-csi"
}

variable "resource_group_location" {
  description = "The location in which the deployment is taking place"
  type        = string
  default     = "eastus"
}

variable "akv_admin_oid" {
  description = "AKV Admin Object ID"
  type        = string
  default     = "b99a3530-636d-4621-8662-bc5c8022b125" // <- Me
}

variable "tags" {
  type        = map(string)
  description = "A map of the tags to use on the resources that are deployed with this module."

  default = {
    Source                                                                     = "terraform"
    Owner                                                                      = "Raki"
    Project                                                                    = "K8s Secret store CSI Arc integration"
    azsecpack                                                                  = "nonprod"
    "platformsettings.host_environment.service.platform_optedin_for_rootcerts" = "true"
  }
}
