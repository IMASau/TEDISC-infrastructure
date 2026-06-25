# Authentication is read from the OpenStack environment.
#
# Recommended for Nectar: download an "openrc" file or create an Application
# Credential from the Nectar dashboard and either
#   * place a clouds.yaml in this directory / ~/.config/openstack/, then set
#     var.os_cloud (or the OS_CLOUD env var), or
#   * `source` the openrc.sh so the OS_* environment variables are present.
#
# Leaving the provider block essentially empty lets it pick everything up from
# that environment, which keeps credentials out of the Terraform state/config.
provider "openstack" {
  cloud = var.os_cloud != "" ? var.os_cloud : null
}
