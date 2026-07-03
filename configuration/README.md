# TEDISC Infrastructure — Ansible Configuration

Provisions a server with:

- **Caddy** — reverse-proxies to a configurable port
- **Podman** — rootless container runtime
- **dagster** - running as system user

## Getting started

```bash
# Python & Ansible deps
pip install -r requirements.txt

# Ansible Galaxy collections
ansible-galaxy collection install -r requirements.yml
```

## Variables

Set these in `inventory/group_vars/all.yml`:

| Variable                   | Default        | Description                      |
| -------------------------- | -------------- | -------------------------------- |
| `caddy_reverse_proxy_port` | `8080`         | Port Caddy proxies to            |
| `caddy_domain`             | `example.com`  | Domain Caddy serves              |
| `caddy_email`              | `admin@...`    | Email for Let's Encrypt TLS      |

## Secrets management

This repo is public, so secrets **must not** be committed in plain text.  Instead, we will use the Nectar secrets manager, so if you have access to the project you can run the playbook.

Note, the Nectar dashboard doesn't expose an interface for secrets, so you will need the `openstack` CLI if you want to update anything (this may mean installing eg `python3-barbicanclient` or similar as the CLI out of the box doesn't support it.  "[Barbican](https://support.ehelp.edu.au/support/solutions/articles/6000248566-nectar-key-manager-service)" is the secret manager).

Store a secret:

```bash
openstack secret store --name caddy_api_key --payload 'supersecret'
```

Retrieve it at runtime in a playbook (requires `OS_*` env vars or `clouds.yaml`):
```yaml
- ansible.builtin.set_fact:
    caddy_api_key: "{{ lookup('openstack_secret', 'caddy_api_key') }}"

# or with an explicit clouds.yaml entry
- ansible.builtin.set_fact:
    caddy_api_key: "{{ lookup('openstack_secret', 'caddy_api_key', cloud='openstack') }}"
```

The lookup plugin is implemented by a custom plugin as there's no official support (eg in the `openstack.cloud.*` plugins)

## Run

```bash
ansible-playbook playbooks/site.yml
```
