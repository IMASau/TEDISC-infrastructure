#!/usr/bin/env bash
# Invoked by lego.service (which loads /etc/lego/env). Issues the cert on
# first run, renews if already issued, then loosens perms so the consuming
# service can read the cert files and (optionally) reloads that service.
set -euo pipefail

: "${LEGO_PATH:?LEGO_PATH must be set}"
: "${LEGO_EMAIL:?LEGO_EMAIL must be set}"
: "${LEGO_DNS_PROVIDER:?LEGO_DNS_PROVIDER must be set}"
: "${LEGO_DOMAINS:?LEGO_DOMAINS must be set (space-separated)}"

# Build --domains flags from the space-separated list.
DOMAIN_ARGS=()
for d in $LEGO_DOMAINS; do
    DOMAIN_ARGS+=(--domains "$d")
done

COMMON_ARGS=(
    --path "$LEGO_PATH"
    --email "$LEGO_EMAIL"
    --dns "$LEGO_DNS_PROVIDER"
    --accept-tos
    "${DOMAIN_ARGS[@]}"
)

# Any existing .crt in the cert dir means we've issued at least once and
# should renew rather than run (which would fail).
if ls "${LEGO_PATH}/certificates/"*.crt >/dev/null 2>&1; then
    /usr/local/bin/lego "${COMMON_ARGS[@]}" renew --days "${LEGO_RENEW_DAYS:-30}"
else
    /usr/local/bin/lego "${COMMON_ARGS[@]}" run
fi

# Make certs readable by the consuming service's group. lego writes 0600 by
# default, which locks Caddy out.
if [ -n "${LEGO_CERT_GROUP:-}" ]; then
    chgrp -R "$LEGO_CERT_GROUP" "$LEGO_PATH/certificates/"
    chmod -R g+rX "$LEGO_PATH/certificates/"
fi

# Reload the consumer so it picks up any renewed material. `|| true` because
# a failed reload shouldn't cause the whole timer run to be logged as failed.
if [ -n "${LEGO_RELOAD_SERVICE:-}" ]; then
    systemctl reload "$LEGO_RELOAD_SERVICE" || true
fi
