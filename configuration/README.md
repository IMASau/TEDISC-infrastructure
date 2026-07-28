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

## Private instance repos and images

`TEDISC-Dagster` is private, and its images on `ghcr.io` should be too. That
needs **two** credentials on the host, and they can't be merged into one:

- **The clone** uses a read-only **deploy key** (SSH). It's scoped to a single
  repo, never expires, and belongs to the repo rather than to a person's
  account.
- **The image pulls** need a **personal access token (classic)** with only the
  `read:packages` scope. A deploy key can't be used here: image pulls are the
  OCI spec over HTTPS with bearer tokens, and there's no SSH transport to plug
  a key into. GitHub does not accept fine-grained PATs for GHCR.

Why not one classic PAT for both? Covering the clone would need the `repo`
scope, which is *full control* of every private repo the owning account can
see — read and write, with no read-only variant. The split keeps each
credential narrow.

Both credentials must persist on the host: `tedisc-deploy@<name>.timer`
re-pulls the repo and images on a schedule, long after the play has finished.

### One-time setup

1. Generate a deploy key. No passphrase — nothing is around to type one in on
   an unattended timer run:
   ```bash
   ssh-keygen -t ed25519 -N '' -C 'tedisc-infra deploy key' -f /tmp/tedisc_deploy_key
   ```

2. Add the **public** half to the repo (not the account): GitHub → the
   `TEDISC-Dagster` repo → Settings → Deploy keys → Add deploy key. Paste
   `/tmp/tedisc_deploy_key.pub`. **Leave "Allow write access" unticked.**

3. Store the **private** half in Barbican, then delete the local copies:
   ```bash
   openstack secret store --name dagster_deploy_key --payload-content-type='text/plain' \
     --payload "$(cat /tmp/tedisc_deploy_key)"
   shred -u /tmp/tedisc_deploy_key /tmp/tedisc_deploy_key.pub
   ```

4. Decide who owns the GHCR token. A classic PAT is tied to a user account, so
   a personal one dies with that account's access — prefer a **machine user**
   (a dedicated GitHub account, e.g. `tedisc-bot`). Package access can be
   granted to a user independently of the repository, so the machine user
   needs read on the *packages* only and never needs access to the source.

5. As that account, create the token: GitHub → Settings → Developer settings →
   Personal access tokens → **Tokens (classic)**. Tick **only** `read:packages`.
   Store it:
   ```bash
   openstack secret store --name dagster_ghcr_token --payload '<token>'
   ```

6. Make the packages private, and grant the machine user read on each. Package
   visibility is **independent of the repo** — making `TEDISC-Dagster` private
   did *not* make these private, so it's a manual change:
   - `ghcr.io/eloisewm/tedisc-dagster/user-code`
   - `ghcr.io/eloisewm/tedisc-dagster/dagster`

   For each: GitHub → Packages → the package → Package settings → Manage
   Actions access / Change visibility.

7. Configure in `inventory/group_vars/all.yml` (the repo URL must be SSH — an
   HTTPS URL with an embedded token would write that token into `.git/config`
   on the host):
   ```yaml
   dagster_deploy_key_secret_name: dagster_deploy_key
   dagster_ghcr_token_secret_name: dagster_ghcr_token
   dagster_ghcr_username: tedisc-bot

   dagster_instances:
     - name: ore
       repo: git@github.com:eloisewm/TEDISC-Dagster.git
   ```

8. Verify before re-running the playbook — both should succeed from your
   laptop with the same credentials:
   ```bash
   GIT_SSH_COMMAND='ssh -i /tmp/tedisc_deploy_key -o IdentitiesOnly=yes' \
     git ls-remote git@github.com:eloisewm/TEDISC-Dagster.git

   echo '<token>' | podman login ghcr.io -u tedisc-bot --password-stdin
   podman pull ghcr.io/eloisewm/tedisc-dagster/user-code:latest
   ```

Then run the playbook. Ansible writes the key to `~dagster/.ssh/id_ed25519`
and the registry credentials to `~dagster/.docker/config.json`, both `0600`.

That `.docker` path on a podman host is deliberate. Rootless podman's default
authfile is `${XDG_RUNTIME_DIR}/containers/auth.json`, under `/run/user/<uid>`
— tmpfs, wiped on reboot, after which the deploy timer would fail to pull.
`~/.docker/config.json` is podman's documented fallback, is persistent, and
needs no `REGISTRY_AUTH_FILE` plumbed into the systemd units (which ship from
the instance repo, not this one).

### Rotating

Deploy key — generate a new one, add it to the repo, then:
```bash
openstack secret delete <old-href>
openstack secret store --name dagster_deploy_key --payload_content_type='text/plain' \
  --payload "$(cat /tmp/new_key)"
```
Remove the old key from the repo's Deploy keys page and re-run the playbook.

GHCR token — regenerate it in the machine user's token settings, then replace
`dagster_ghcr_token` in Barbican the same way and re-run.

### Notes

- The clone uses `accept_hostkey: true`, i.e. trust-on-first-use for
  github.com's host key. The exposure is a first-run-only window and pinning
  would need maintenance when GitHub rotates keys (as they did in 2023), but
  it's worth knowing it's a TOFU rather than a pin.
- `~dagster/.docker/config.json` stores `base64(user:token)` — that's
  encoding, not encryption. Mode `0600` is what protects it, same as the
  `.env` files alongside it, which already hold DB passwords.

## SSH access to the Nectar processing VM

The dagster pipelines SSH into the Nectar processing VM to run jobs there,
configured by three env vars: `NECTAR_INSTANCE_IP`, `NECTAR_SSH_USER` and
`NECTAR_SSH_KEY`. The plumbing spans both playbooks:

- `processing.yml` creates a dedicated service user (`processing_user`, no
  sudo, nothing else on the box runs as it) and installs the **public** half
  of a keypair in its `authorized_keys`.
- `dagster.yml` writes the **private** half next to each instance checkout
  (`<checkout>/nectar_ssh_key`, mode `0600`), where the containers can reach
  it.

`NECTAR_SSH_KEY` holds the *in-container path* to that file, not the key
material — a multi-line PEM wouldn't survive the sourceable `.env` format.
All three vars ride the normal per-instance `env:` map in
`inventory/group_vars/all.yml`.

Barbican can't generate ed25519 keys (its Orders API is RSA-only), so the
keypair is generated locally and both halves stored as ordinary secrets:

### One-time setup

```bash
ssh-keygen -t ed25519 -N '' -C 'tedisc nectar processing' -f /tmp/nectar_key
openstack secret store --name nectar_ssh_private_key \
  --payload-content-type='text/plain' --payload "$(cat /tmp/nectar_key)"
openstack secret store --name nectar_ssh_public_key \
  --payload-content-type='text/plain' --payload "$(cat /tmp/nectar_key.pub)"
shred -u /tmp/nectar_key /tmp/nectar_key.pub
```

No passphrase, for the same reason as the deploy key: nothing is around to
type one in when a pipeline run fires.

### Rotating

Generate and store a new pair as above (`openstack secret delete` the old
hrefs first), then re-run **both** playbooks — `processing.yml` to swap the
authorized key, `dagster.yml` to swap the private key files. The old public
key lingers in `authorized_keys` until removed (the play only ever adds), so
delete it manually if the rotation is revoking access rather than routine.

## Run

```bash
ansible-playbook playbooks/site.yml
```
