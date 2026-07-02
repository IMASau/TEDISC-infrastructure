# Resolve the image by name.
data "openstack_images_image_v2" "vm" {
  name        = var.image_name
  most_recent = true
}

# Resolve the flavor. Either by explicit name, or by finding one that matches
# the requested vcpus/ram. The openstack_compute_flavor_v2 data source returns
# the smallest flavor satisfying the given constraints.
data "openstack_compute_flavor_v2" "vm" {
  name  = var.flavor_name != "" ? var.flavor_name : null
  vcpus = var.flavor_name == "" ? var.vcpus : null
  ram   = var.flavor_name == "" ? var.ram_mb : null
}

# The project network the instance's port lives on.
data "openstack_networking_network_v2" "vm" {
  name = var.network_name
}

resource "openstack_compute_instance_v2" "vm" {
  name            = var.instance_name
  flavor_id       = data.openstack_compute_flavor_v2.vm.id
  key_pair        = var.key_pair_name
  security_groups = var.security_groups

  block_device {
    uuid                  = data.openstack_images_image_v2.vm.id
    source_type           = "image"
    destination_type      = "local"
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    uuid = data.openstack_networking_network_v2.vm.id
  }

  lifecycle {
    # The image can be updated upstream without forcing a rebuild of a running VM.
    ignore_changes = [block_device[0].uuid]
  }
}

# The floating IP is allocated out-of-band (e.g. `openstack floating ip create`)
# so that it survives `tofu destroy` and stays valid for external whitelists.
# We look it up here rather than owning it as a resource.
data "openstack_networking_floatingip_v2" "vm" {
  address = var.floating_ip_address
}

# The neutron port that the instance created on the project network.
data "openstack_networking_port_v2" "vm" {
  device_id  = openstack_compute_instance_v2.vm.id
  network_id = data.openstack_networking_network_v2.vm.id
}

# Bind the floating IP to the instance's port.
resource "openstack_networking_floatingip_associate_v2" "vm" {
  floating_ip = data.openstack_networking_floatingip_v2.vm.address
  port_id     = data.openstack_networking_port_v2.vm.id
}
