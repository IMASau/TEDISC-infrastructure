# Dagster Infrastructure

This is the infrastructure-as-code for the ORE/MH Dagster infrastucture.  Compute will be hosted in NeCTAR, with RDSI storage mounted.

## Physical Infrastructure

This uses [terraform](https://developer.hashicorp.com/terraform) (or [opentofu](https://opentofu.org/) --- I use tofu but it should work with either) to manage the virtual machines and associated infrastructure.  See the [README](infrastructure/README.md) in the subdirectory for how to run, etc.

## Software Configuration

The VM configuration is managed by [Ansible](https://docs.ansible.com/projects/ansible/latest/index.html).  See the [README](configuration/README.md) in the subdirectory for how to run, etc.

<!-- TODO: diagram -->
