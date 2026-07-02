variable "os_cloud" {
  description = "Name of the cloud entry in clouds.yaml to use. Leave empty to authenticate from OS_* environment variables (e.g. a sourced openrc.sh)."
  type        = string
  default     = ""
}

variable "instance_name" {
  description = "Name of the virtual machine."
  type        = string
  default     = "tedisc-vm"
}

# --- Sizing -----------------------------------------------------------------
# Nectar exposes fixed flavors; you cannot set arbitrary CPU/RAM. These two
# variables are used to look up the smallest matching flavor. If you already
# know the exact flavor name, set var.flavor_name to skip the lookup.

variable "vcpus" {
  description = "Number of vCPUs. Used to find a matching Nectar flavor when flavor_name is empty."
  type        = number
  default     = 2
}

variable "ram_mb" {
  description = "Amount of RAM in MB. Used to find a matching Nectar flavor when flavor_name is empty."
  type        = number
  default     = 8192
}

variable "flavor_name" {
  description = "Explicit flavor name (e.g. \"m3.medium\"). Overrides vcpus/ram_mb lookup when set."
  type        = string
  default     = ""
}

# --- Image / access ---------------------------------------------------------

variable "image_name" {
  description = "Name of the image to boot from."
  type        = string
  default     = "NeCTAR Ubuntu 22.04 LTS (Jammy) amd64"
}

variable "key_pair_name" {
  description = "Name of an existing OpenStack key pair to inject for SSH access."
  type        = string
}

variable "security_groups" {
  description = "Security groups to attach to the instance."
  type        = list(string)
  default     = ["default"]
}

# --- Networking -------------------------------------------------------------

variable "network_name" {
  description = "Name of the project network to attach the instance to."
  type        = string
  default     = "default"
}

variable "floating_ip_address" {
  description = "Pre-allocated floating IP address to attach to the instance. Allocate once with `openstack floating ip create <pool>` (or via the Nectar dashboard) so the address survives destroy/recreate cycles and stays valid for external whitelists."
  type        = string
}
