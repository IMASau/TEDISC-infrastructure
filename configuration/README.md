# TEDISC Infrastructure — Ansible Configuration

Provisions a server with:

- **Caddy** — reverse-proxies to a configurable port
- **Podman** — rootless container runtime
- **dagster** — running as system user

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

The instance repos and their images live on a self-hosted **Gitea**, and are
private. Both the clone and the image pulls authenticate as a single
read-only **bot user**:

- Gitea accepts the same access token for git-over-HTTPS and for its
  container registry, so one credential covers both.
- The Gitea host offers no SSH, so deploy keys are out; everything is HTTPS.
- Gitea has nothing like a GitHub App's short-lived installation tokens (no
  deploy tokens, no client-credentials grant), so the token itself is the
  durable credential. Rotation is manual (see below).

The token is stored in Barbican and the role renders it into the stock
credential files git and podman read on their own, which is what lets
`tedisc-deploy@<name>.timer` keep pulling long after the play has finished:

- `~sa-container/.gitconfig` sets `credential.helper = store` for the Gitea
  host, and `~sa-container/.git-credentials` (`0600`) holds the URL-encoded
  `https://<user>:<token>@<host>` line. Nothing lands in `.git/config`.
- `~sa-container/.docker/config.json` (`0600`) holds an `auths` entry for the
  registry host — the same base64 `user:token` that `podman login` would
  write, so there is no login step and nothing to redo after a reboot.

The instance repo's units and `deploy-update.sh` need no changes — the files
sit underneath the stock git/podman credential machinery, and since we have
no root on this host (it's administered by UTAS; we only have the
`sa-container` user), everything lives in that user's home. Unlike the
previous GitHub App setup there are no helper scripts, no per-unit drop-ins,
and no per-owner configuration: whatever the bot user can see, the host can
pull.

That `.docker` path on a podman host is deliberate. Rootless podman's default
authfile is `${XDG_RUNTIME_DIR}/containers/auth.json`, under `/run/user/<uid>`
— tmpfs, wiped on reboot, after which the deploy timer would fail to pull.
`~/.docker/config.json` is podman's documented fallback, is persistent, and
needs no `REGISTRY_AUTH_FILE` plumbed into the systemd units (which ship from
the instance repo, not this one).

### One-time setup

1. Create the bot user in Gitea (site admin → Users → Create, or
   self-registration if enabled), e.g. `tedisc-deploy`. Give it a long random
   password nobody needs to remember; it only ever authenticates by token.

2. Grant it read access to every owner whose repos or images the instances
   use. For an organisation: add it to a team with **Read** on the
   **Code** and **Packages** units. For a personal account: add it as a
   collaborator (Read) on each repo. Token scopes only restrict what
   membership already grants, so this step is what actually opens the door.

3. Issue an access token as that user: Settings → Applications → Generate
   token, with scopes **`read:repository`** and **`read:package`** only.
   Copy it once — Gitea never shows it again — and store it in Barbican:
   ```bash
   openstack secret store --name dagster_gitea_token \
     --payload-content-type='text/plain' --payload '<token>'
   ```

4. Verify from your laptop before touching the playbook — this is the step
   that catches a missing team membership or a wrong image path:
   ```bash
   HOST=<gitea-host> USER=tedisc-deploy TOKEN=<token>
   git ls-remote "https://${USER}:${TOKEN}@${HOST}/IMAS/imas-ore.git"
   echo "$TOKEN" | podman login "$HOST" -u "$USER" --password-stdin
   podman pull "${HOST}/imas/tedisc-dagster/user-code:latest"
   podman logout "$HOST"
   ```
   Gitea lowercases the owner in image paths. Nested image names
   (`owner/tedisc-dagster/user-code`) are supported by current Gitea; if the
   pull 404s, try a flat name.

5. Configure in `inventory/group_vars/all.yml` (repo URLs must be HTTPS):
   ```yaml
   dagster_registry: gitea.example.edu.au   # scopes both git and podman auth
   dagster_gitea_user: tedisc-deploy
   dagster_gitea_token_secret_name: dagster_gitea_token

   dagster_instances:
     - name: ore
       repo: https://git.its.utas.edu.au/IMAS/imas-ore.git
       user_code_image: git. its. utas.edu.au/imas/tedisc-dagster/user-code:latest
   ```

Then run the playbook. The first run after the GitHub → Gitea cutover also
removes the old GitHub App helper, shim, key and unit drop-ins from the host.

### Rotating

Gitea tokens don't expire, so rotation is a deliberate act. Generate a new
token for the bot user (the old one stays valid until deleted, so there's no
gap), then:
```bash
openstack secret delete <old-href>
openstack secret store --name dagster_gitea_token \
  --payload-content-type='text/plain' --payload '<new-token>'
```
Re-run the playbook, confirm a pull works, then delete the old token under
the bot user's Settings → Applications. Revoking is immediate: delete the
token there and both git and podman start failing on the next pull.

### Notes

- Pulls need the Gitea host reachable on 443 when the deploy timer fires; an
  outage skips that run the same way a failed pull always has. There is no
  separate API call to mint anything.
- The token sits in two files on the host (`~/.git-credentials` and
  `~/.docker/config.json`), both `0600` and readable only by `sa-container`.
  Both are rendered from the one Barbican secret, so rotation is a single
  play run. Keep the bot user strictly read-only so a leak of either file
  only ever exposes read access.
- Image builds and pushes happen in the instance repo's CI, not here. That
  pipeline needs write access to the Gitea registry (Gitea Actions'
  built-in token, or a second write-scoped token) — out of scope for this
  repo.

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
