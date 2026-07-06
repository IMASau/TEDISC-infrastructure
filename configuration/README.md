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

## ACME certs via lego + Designate DNS-01

Because our security group only permits inbound HTTP/HTTPS from a UTas CIDR, Let's Encrypt's ACME validators can't reach the server for the HTTP-01 / TLS-ALPN-01 challenges. We instead use the DNS-01 challenge, which proves domain control by writing a TXT record in Designate — no inbound access needed.

There's no maintained Caddy module for OpenStack Designate (the one that existed hasn't been updated in years and no longer builds), so we do ACME with [**lego**](https://go-acme.github.io/lego/) — a maintained Go ACME client with a working Designate provider — and hand the resulting cert files to Caddy via `tls <cert> <key>`. Renewal runs on a daily systemd timer that reloads Caddy on success.

The whole thing needs an OpenStack **application credential** that can write records in the Designate zone. Only the credential id and secret are stored — no username/password.

### One-time setup

1. Create the application credential. `--unrestricted` is required because lego uses it to manage tokens on the fly:
   ```bash
   openstack application credential create tedisc-acme \
     --description "lego DNS-01 ACME challenges" \
     --unrestricted
   ```
   Copy the `id` and `secret` from the output — the secret is only shown once.

   Note: you cannot create an application credential from a session that is *already* authenticated as one. Use the Nectar dashboard (Identity → Application Credentials) or a password-based `openrc.sh` to do the initial creation.

2. Store both in Barbican:
   ```bash
   openstack secret store --name caddy_appcred_id     --payload '<id-from-step-1>'
   openstack secret store --name caddy_appcred_secret --payload '<secret-from-step-1>'
   ```

3. Verify the credential can actually write records (before re-running the playbook — saves debugging a failed Ansible run):
   ```bash
   openstack --os-auth-type v3applicationcredential \
             --os-auth-url https://keystone.rc.nectar.org.au/v3/ \
             --os-application-credential-id '<id>' \
             --os-application-credential-secret '<secret>' \
             recordset list ore-tedisc.cloud.edu.au.
   ```
   You should see the existing records for your zone. A permission error here means the credential needs additional roles — either recreate it without `--role` so it inherits your project defaults, or ask a project admin what role is needed for Designate write.

4. Configure in `inventory/group_vars/all.yml`:
   ```yaml
   lego_email: you@example.com
   lego_domains: ["*.dagster.ore-tedisc.cloud.edu.au"]
   lego_openstack_auth_url: "https://keystone.rc.nectar.org.au/v3/"
   lego_openstack_region: "Tasmania"      # verify with `openstack region list`
   lego_appcred_id_secret_name: caddy_appcred_id
   lego_appcred_secret_secret_name: caddy_appcred_secret

   # Cert paths Caddy consumes. Filename is derived from lego_domains[0]
   # with '*' replaced by '_'.
   caddy_cert_file: "/var/lib/lego/certificates/_.dagster.ore-tedisc.cloud.edu.au.crt"
   caddy_key_file:  "/var/lib/lego/certificates/_.dagster.ore-tedisc.cloud.edu.au.key"
   ```

5. Run the playbook. On first run Ansible will download the lego binary from GitHub releases, render `/etc/lego/env` with the Barbican-fetched credentials, install `lego.service` + `lego.timer`, trigger the initial issuance, and set Caddy's Caddyfile to serve the resulting wildcard cert. Watch progress with:
   ```bash
   sudo journalctl -u lego.service -f
   sudo journalctl -u caddy -f
   ```

### Rotating the credential

If the credential is ever leaked or you want to rotate it:

```bash
openstack application credential delete tedisc-acme
openstack application credential create tedisc-acme --unrestricted
openstack secret delete <old-id-href>
openstack secret delete <old-secret-href>
openstack secret store --name caddy_appcred_id     --payload '<new-id>'
openstack secret store --name caddy_appcred_secret --payload '<new-secret>'
```

Then re-run the playbook; the templated env file is overwritten and lego picks up the new credential on the next renewal (or `sudo systemctl start lego.service` to force one now).

## Run

```bash
ansible-playbook playbooks/site.yml
```
