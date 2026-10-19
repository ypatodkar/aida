#!/bin/bash
# Caddy renews the six-day IP certificate; LiveKit loads its copy at startup.
# Run as root every 15 minutes. A changed certificate restarts LiveKit, which
# briefly interrupts a call if one is in progress. Suitable for this test host.
set -euo pipefail
cd /opt/aida
exec 9>/run/aida-turn-cert.lock
flock -n 9 || exit 0
cert=$(find caddy-data/caddy/certificates/acme-v02.api.letsencrypt.org-directory -name '*.crt' -type f -print -quit)
test -n "$cert"
key="${cert%.crt}.key"
openssl x509 -in "$cert" -noout -checkend 3600 >/dev/null
if cmp -s "$cert" turn-certs/cert.pem && cmp -s "$key" turn-certs/key.pem; then
  exit 0
fi
mkdir -p turn-certs
chmod 700 turn-certs
install -m 600 "$cert" turn-certs/cert.pem.new
install -m 600 "$key" turn-certs/key.pem.new
mv turn-certs/cert.pem.new turn-certs/cert.pem
mv turn-certs/key.pem.new turn-certs/key.pem
docker compose -f deploy/compose.aws.yaml restart livekit
