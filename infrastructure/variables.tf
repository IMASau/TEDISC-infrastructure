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
  description = "Baseline security groups to attach to the instance's port, in addition to the SSH group this module creates. Nectar's \"default\" group allows intra-group traffic and full egress."
  type        = list(string)
  default     = ["default"]
}

variable "ssh_ingress_cidrs" {
  description = "CIDR ranges allowed to reach tcp/22 on the instance. Materialised as rules on a dedicated <instance_name>-ssh security group."
  type        = list(string)
  default     = ["131.217.0.0/16"]
}

# --- Networking -------------------------------------------------------------
# Nectar Advanced Networking: Terraform owns a private network, subnet, and
# router in the project. The router's gateway is set to a Nectar zone network
# (external_network_name), which is also the pool the floating IP is drawn
# from. Only the floating IP is out-of-band so its address survives destroy.

variable "external_network_name" {
  description = "Name of Nectar's external network for the router gateway and the FIP pool (e.g. \"tasmania\", \"melbourne\", \"qld\"). Match your allocation's zone."
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the private project subnet. Internal only; any RFC1918 range works."
  type        = string
  default     = "192.168.100.0/24"
}

variable "floating_ip_address" {
  description = "Pre-allocated floating IP to attach to the instance. Allocate once with `openstack floating ip create <external_network_name>` so it survives destroy/recreate and stays valid for external whitelists."
  type        = string
}
