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

# Nectar's external (provider) network — the router's gateway and the pool the
# floating IP was allocated from.
data "openstack_networking_network_v2" "external" {
  name     = var.external_network_name
  external = true
}

# Private project network + subnet + router. All Terraform-owned so we can
# destroy and recreate freely; the whitelisted IP lives on the floating IP
# which is allocated out-of-band and referenced as a data source below.
resource "openstack_networking_network_v2" "vm" {
  name           = "${var.instance_name}-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "vm" {
  name       = "${var.instance_name}-subnet"
  network_id = openstack_networking_network_v2.vm.id
  cidr       = var.subnet_cidr
  ip_version = 4
}

resource "openstack_networking_router_v2" "vm" {
  name                = "${var.instance_name}-router"
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "vm" {
  router_id = openstack_networking_router_v2.vm.id
  subnet_id = openstack_networking_subnet_v2.vm.id
}

resource "openstack_networking_secgroup_v2" "ssh" {
  name        = "${var.instance_name}-ssh"
  description = "SSH ingress for ${var.instance_name}"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  for_each          = toset(var.ssh_ingress_cidrs)
  security_group_id = openstack_networking_secgroup_v2.ssh.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
}

resource "openstack_networking_secgroup_v2" "web" {
  name        = "${var.instance_name}-web"
  description = "HTTP/HTTPS ingress for ${var.instance_name}"
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  for_each          = toset(var.web_ingress_cidrs)
  security_group_id = openstack_networking_secgroup_v2.web.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = each.value
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  for_each          = toset(var.web_ingress_cidrs)
  security_group_id = openstack_networking_secgroup_v2.web.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = each.value
}

resource "openstack_compute_instance_v2" "vm" {
  name      = var.instance_name
  image_id  = data.openstack_images_image_v2.vm.id
  flavor_id = data.openstack_compute_flavor_v2.vm.id
  key_pair  = var.key_pair_name
  security_groups = concat(
    var.security_groups,
    [
      openstack_networking_secgroup_v2.ssh.name,
      openstack_networking_secgroup_v2.web.name,
    ],
  )

  network {
    uuid = openstack_networking_network_v2.vm.id
  }

  # The subnet must be joined to the router before boot, otherwise DHCP and
  # metadata may not be reachable.
  depends_on = [openstack_networking_router_interface_v2.vm]

  lifecycle {
    # Nectar can republish the image under the same name; don't rebuild the VM
    # just because the upstream UUID changed.
    ignore_changes = [image_id]
  }
}

# The pre-allocated floating IP. Owned out-of-band (`openstack floating ip
# create <external_network>`) so the address survives destroy/recreate.
data "openstack_networking_floatingip_v2" "vm" {
  address = var.floating_ip_address
}

# The neutron port nova created for the instance on the private network.
data "openstack_networking_port_v2" "vm" {
  device_id  = openstack_compute_instance_v2.vm.id
  network_id = openstack_networking_network_v2.vm.id
}

# Bind the floating IP to the instance's port.
resource "openstack_networking_floatingip_associate_v2" "vm" {
  floating_ip = data.openstack_networking_floatingip_v2.vm.address
  port_id     = data.openstack_networking_port_v2.vm.id
}

# Optional Designate A record pointing at the floating IP. Turned on by setting
# dns_zone_name (and dns_hostname) in tfvars.
data "openstack_dns_zone_v2" "vm" {
  count = var.dns_zone_name == "" ? 0 : 1
  name  = var.dns_zone_name
}

resource "openstack_dns_recordset_v2" "vm" {
  count       = var.dns_zone_name == "" ? 0 : 1
  zone_id     = data.openstack_dns_zone_v2.vm[0].id
  name        = "${var.dns_hostname}.${var.dns_zone_name}"
  description = "A record for ${var.instance_name}"
  ttl         = var.dns_ttl
  type        = "A"
  records     = [data.openstack_networking_floatingip_v2.vm.address]
}
