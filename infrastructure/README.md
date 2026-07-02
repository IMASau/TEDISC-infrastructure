# TEDISC infrastructure — Nectar VM (OpenTofu)

Provisions a single virtual machine on [Nectar](https://nectar.org.au/) (OpenStack)
with a static floating IP. CPU and RAM are configurable.

## Layout

| File | Purpose |
|------|---------|
| `versions.tf` | Required OpenTofu + provider versions |
| `provider.tf` | OpenStack provider (auth from environment/clouds.yaml) |
| `variables.tf` | Input variables |
| `main.tf` | Instance, flavor/image lookup, floating IP |
| `outputs.tf` | IP address, instance id, resolved flavor, etc. |
| `terraform.tfvars.example` | Template for your settings |

## Prerequisites

- [OpenTofu](https://opentofu.org/) `>= 1.6`
- A Nectar project and credentials. From the Nectar dashboard, create an
  **Application Credential** (Identity → Application Credentials) and download
  either the `clouds.yaml` or the `openrc.sh`.
- An existing SSH **key pair** in the project (Compute → Key Pairs).
- A pre-allocated **floating IP**. Terraform does *not* own the IP so that it
  survives `tofu destroy` and stays valid for external whitelists. Allocate
  once with `openstack floating ip create <pool>` (pool from
  `openstack network list --external`), or via the Nectar dashboard, and
  set the address in `terraform.tfvars` as `floating_ip_address`.

## Authentication

Pick one:

**clouds.yaml** — place it in this directory or `~/.config/openstack/`, then set
`os_cloud` (in `terraform.tfvars`) or `export OS_CLOUD=openstack`.

**openrc.sh** — `source ./openrc.sh` before running tofu and leave `os_cloud` empty.

## Usage

```sh
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: key_pair_name, floating_ip_address, vcpus, ram_mb, ...

tofu init
tofu plan
tofu apply
```

After apply, the static IP is printed:

```sh
tofu output floating_ip
tofu output ssh_command
```

## Sizing

Nectar only offers fixed flavors, so you can't request arbitrary CPU/RAM.
Set `vcpus` and `ram_mb` and the config looks up the smallest matching flavor.
If the combination doesn't match any flavor the plan will error — in that case
set `flavor_name` directly (see `openstack flavor list`).

## Finding the right names

```sh
openstack network list --external   # pool to allocate the floating IP from
openstack floating ip list          # -> floating_ip_address (after allocation)
openstack network list              # -> network_name (your project network)
openstack flavor list               # -> flavor_name / valid vcpus+ram combos
openstack image list                # -> image_name
openstack keypair list              # -> key_pair_name
```

## Destroy

```sh
tofu destroy
```

This tears down the VM and its floating-IP association, but leaves the
floating IP allocated to the project so the same address can be reused on
the next `tofu apply`. To release the IP entirely:

```sh
openstack floating ip delete <address>
```
