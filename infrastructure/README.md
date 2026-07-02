# TEDISC infrastructure — Nectar VM (OpenTofu)

Provisions a single virtual machine on [Nectar](https://nectar.org.au/) (OpenStack)
using Nectar's Advanced Networking: a Terraform-owned private network, subnet,
and router, plus an out-of-band floating IP that survives destroy/recreate so
its address stays stable for external whitelists. CPU and RAM are configurable.

## Layout

| File | Purpose |
|------|---------|
| `versions.tf` | Required OpenTofu + provider versions |
| `provider.tf` | OpenStack provider (auth from environment/clouds.yaml) |
| `variables.tf` | Input variables |
| `main.tf` | Network/subnet/router, instance, flavor/image lookup, floating IP |
| `outputs.tf` | IP address, instance id, resolved flavor, etc. |
| `terraform.tfvars.example` | Template for your settings |

## Prerequisites

- [OpenTofu](https://opentofu.org/) `>= 1.6`
- A Nectar project and credentials. From the Nectar dashboard, create an
  **Application Credential** (Identity → Application Credentials) and download
  either the `clouds.yaml` or the `openrc.sh`.
- An existing SSH **key pair** in the project (Compute → Key Pairs).
- A pre-allocated **floating IP**. Terraform does *not* own the FIP, so it
  survives `tofu destroy` and stays valid for external whitelists. Allocate
  once from the same external network your allocation is in:

  ```sh
  openstack floating ip create tasmania
  ```

  Note the address it prints and set it in `terraform.tfvars` as
  `floating_ip_address`.

## Authentication

Pick one:

**clouds.yaml** — place it in this directory or `~/.config/openstack/`, then set
`os_cloud` (in `terraform.tfvars`) or `export OS_CLOUD=openstack`.

**openrc.sh** — `source ./openrc.sh` before running tofu and leave `os_cloud` empty.

## Usage

```sh
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: key_pair_name, external_network_name, floating_ip_address, ...

tofu init
tofu plan
tofu apply
```

After apply, the IP is printed:

```sh
tofu output floating_ip
tofu output ssh_command
```

## What gets created

- Private network `${instance_name}-net` and subnet `${instance_name}-subnet`
  (default CIDR `192.168.100.0/24`, override with `subnet_cidr`).
- Router `${instance_name}-router` with its external gateway set to the Nectar
  zone network (`external_network_name`).
- The VM, attached to the private network.
- An association binding the pre-existing floating IP to the VM's port.

`tofu destroy` tears down everything above **except** the floating IP itself.
The next `tofu apply` reattaches the same IP.

## Sizing

Nectar only offers fixed flavors, so you can't request arbitrary CPU/RAM.
Set `vcpus` and `ram_mb` and the config looks up the smallest matching flavor.
If the combination doesn't match any flavor the plan will error — in that case
set `flavor_name` directly (see `openstack flavor list`).

## Finding the right names

```sh
openstack network list --external   # -> external_network_name (your zone)
openstack floating ip list          # -> floating_ip_address (after allocation)
openstack flavor list               # -> flavor_name / valid vcpus+ram combos
openstack image list                # -> image_name
openstack keypair list              # -> key_pair_name
openstack security group list       # -> security_groups
```

## Destroy

```sh
tofu destroy
```

Leaves the floating IP allocated to the project so the same address can be
reused on the next `tofu apply`. To release it entirely:

```sh
openstack floating ip delete <address>
```
