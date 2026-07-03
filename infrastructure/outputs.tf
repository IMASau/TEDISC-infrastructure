output "instance_id" {
  description = "OpenStack UUID of the instance."
  value       = openstack_compute_instance_v2.vm.id
}

output "instance_name" {
  description = "Name of the instance."
  value       = openstack_compute_instance_v2.vm.name
}

output "flavor_name" {
  description = "Flavor that was selected."
  value       = data.openstack_compute_flavor_v2.vm.name
}

output "flavor_specs" {
  description = "Resolved vCPUs and RAM (MB) of the selected flavor."
  value = {
    vcpus  = data.openstack_compute_flavor_v2.vm.vcpus
    ram_mb = data.openstack_compute_flavor_v2.vm.ram
  }
}

output "floating_ip" {
  description = "Static/floating IP address assigned to the instance."
  value       = data.openstack_networking_floatingip_v2.vm.address
}

output "fqdn" {
  description = "FQDN registered in Designate, or empty string if DNS is disabled."
  value       = var.dns_zone_name == "" ? "" : trimsuffix("${var.dns_hostname}.${var.dns_zone_name}", ".")
}

output "ssh_command" {
  description = "Convenience SSH command (adjust the username for your image)."
  value       = "ssh ubuntu@${var.dns_zone_name == "" ? data.openstack_networking_floatingip_v2.vm.address : trimsuffix("${var.dns_hostname}.${var.dns_zone_name}", ".")}"
}
