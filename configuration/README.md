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

`TEDISC-Dagster` is private, and its images on `ghcr.io` should be too. Both
the clone and the image pulls authenticate through a single **GitHub App**
installation with two read-only permissions:

- **`contents: read`** — the clones and `git pull`s (over HTTPS).
- **`packages: read`** — the `ghcr.io` image pulls.

This replaced an earlier deploy-key + classic-PAT pair. One credential
instead of two, it's read-only, it's scoped to exactly the repos the
installations grant (a deploy key is single-repo; a classic PAT is
account-wide), and it belongs to the app rather than to a person's account.
GHCR accepts App installation tokens (unlike fine-grained PATs, which it
still rejects).

Installations are per GitHub **account**: one app, installed on each account
that owns instance repos, each installation granting the relevant repos.
`dagster_github_app_installations` maps owner → installation id, and the
owner is resolved per operation — git passes the repo path to the credential
helper (`useHttpPath`), while podman only ever tells helpers the registry
hostname, so each unit instance carries its image owner in a
`GITHUB_APP_OWNER` environment drop-in instead (derived from the instance's
repo URL, or set explicitly with `github_owner:`).

The catch: installation tokens **expire after an hour**, and
`tedisc-deploy@<name>.timer` re-pulls the repo and images on a schedule, long
after the play has finished. So Ansible never installs a token. It installs
the app's **private key** (from Barbican) plus a mint-and-cache script,
`~sa-container/.local/bin/github-app-token`, and wires git and podman to call
it *at pull time*:

- `~sa-container/.gitconfig` sets a `credential.helper` for `github.com`, so
  every HTTPS git operation — the play-time clone and the timer's later
  pulls — fetches a fresh token. Nothing lands in `.git/config`.
- `~sa-container/.docker/config.json` maps `ghcr.io` to a
  `docker-credential-github-app` helper (a shim around the same script), so
  every podman pull does likewise. Tokens are cached (`~/.cache/github-app/`,
  `0600`) and re-minted when within 5 minutes of expiry.

The instance repo's units and `deploy-update.sh` needed no changes — the
helpers sit underneath the stock git/podman credential machinery. And since
we have no root on this host (it's administered by UTAS; we only have the
`sa-container` user), everything lives in that user's home. The one wrinkle:
podman finds the `docker-credential-*` shim via the unit's `$PATH`, which by
default excludes `~/.local/bin` — the role adds per-unit drop-ins
(`~/.config/systemd/user/tedisc*@.service.d/`) that prepend it, leaving the
shipped unit files untouched.

### One-time setup

1. Create the GitHub App (owner: the account that owns the repos): GitHub →
   Settings → Developer settings → GitHub Apps → New GitHub App. Untick
   **Webhook → Active** (no webhook), set Repository permissions **Contents:
   Read-only** and **Packages: Read-only**, and restrict to "Only on this
   account". Note the **App ID** from the app's settings page.

2. Install the app on **each account that owns instance repos**, granting
   **only** those repos (Install App → select repositories). Each
   installation's ID is the trailing number in its URL
   (`…/settings/installations/<id>`); adding a repo under an
   already-installed account is just a checkbox on that page, no new IDs.

3. Generate a private key (app settings page → Private keys), then store the
   downloaded PEM in Barbican and delete the local copy:
   ```bash
   openstack secret store --name dagster_github_app_key \
     --payload-content-type='text/plain' --payload "$(cat /tmp/tedisc-app.*.pem)"
   shred -u /tmp/tedisc-app.*.pem
   ```

4. Make the packages private. Package visibility is **independent of the
   repo** — making `TEDISC-Dagster` private did *not* make these private:
   - `ghcr.io/eloisewm/tedisc-dagster/user-code`
   - `ghcr.io/eloisewm/tedisc-dagster/dagster`

   Installation tokens can pull a package when it's **connected to a repo the
   installation covers** — true automatically for images pushed from Actions
   with `GITHUB_TOKEN`; otherwise connect it under Package settings.

5. Verify from your laptop before touching the playbook — this is the step
   that catches a mis-granted installation or an unconnected package. Repeat
   per installation if there's more than one:
   ```bash
   APP_ID=<id> INST_ID=<id> KEY=/tmp/tedisc-app.pem
   b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
   now=$(date +%s)
   hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
   pay=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now-60)) $((now+540)) "$APP_ID" | b64)
   sig=$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -sha256 -sign "$KEY" | b64)
   TOKEN=$(curl -sf -X POST -H "Authorization: Bearer $hdr.$pay.$sig" \
     "https://api.github.com/app/installations/$INST_ID/access_tokens" \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

   git ls-remote "https://x-access-token:${TOKEN}@github.com/eloisewm/TEDISC-Dagster.git"
   echo "$TOKEN" | podman login ghcr.io -u x-access-token --password-stdin
   podman pull ghcr.io/eloisewm/tedisc-dagster/user-code:latest
   ```

6. Configure in `inventory/group_vars/all.yml` (repo URLs must be HTTPS —
   installation tokens are HTTPS credentials):
   ```yaml
   dagster_github_app_id: "123456"
   dagster_github_app_installations:
     eloisewm: "12345678"
     # another-owner: "23456789"   # app must be installed there too
   dagster_github_app_key_secret_name: dagster_github_app_key

   dagster_instances:
     - name: ore
       repo: https://github.com/eloisewm/TEDISC-Dagster.git
       # github_owner: another-owner   # only if the images' owner differs
       #                               # from the repo owner
   ```

Then run the playbook. On the host, `~/.local/bin/github-app-token token
<owner>` (run as `sa-container`) prints a token for debugging; the owner
argument is optional when only one installation is configured.

That `.docker` path on a podman host is deliberate. Rootless podman's default
authfile is `${XDG_RUNTIME_DIR}/containers/auth.json`, under `/run/user/<uid>`
— tmpfs, wiped on reboot, after which the deploy timer would fail to pull.
`~/.docker/config.json` is podman's documented fallback, is persistent, and
needs no `REGISTRY_AUTH_FILE` plumbed into the systemd units (which ship from
the instance repo, not this one).

### Rotating

App settings page → Private keys → generate a new key (both keys stay valid
until one is deleted, so there's no gap), then:
```bash
openstack secret delete <old-href>
openstack secret store --name dagster_github_app_key \
  --payload-content-type='text/plain' --payload "$(cat /tmp/new.pem)"
```
Re-run the playbook, confirm a pull works, then delete the old key on the app
settings page. Revoking is immediate: delete the key there and every token it
could mint dies with it (existing tokens expire within the hour regardless).

### Notes

- Minting needs `api.github.com` reachable when the deploy timer fires; an
  outage skips that run the same way a failed pull always has. The ≤1 h token
  cache smooths transient blips.
- The JWT the script signs is backdated 60 s against clock skew (GitHub
  rejects future-dated JWTs); with systemd-timesyncd running this should
  never matter.
- `~sa-container/.docker/config.json` no longer contains any secret — just
  the `credHelpers` wiring. The only durable secret on the host is the app's
  PEM (`0600`, readable only by `sa-container`).

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
