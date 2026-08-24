#!/usr/bin/env bash
#
# Runs the consumer container without writing the token anywhere: it is derived
# from nexus/.credentials at call time and passed through the environment.
#
# Usage:
#   consumer/run.sh              # resolve the app against production
#   consumer/run.sh negative     # ask for an unapproved package, expect failure
#   consumer/run.sh shell        # poke around inside
#
# The URL defaults to the tailnet hostname; override with NEXUS_PRODUCTION_URL.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
CREDS="$ROOT/nexus/.credentials"

[[ -f "$CREDS" ]] || { echo "Missing $CREDS. Run nexus/bootstrap.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$CREDS"; set +a

: "${NEXUS_PUB_CONSUMER_PASSWORD:?pub-consumer password not found in nexus/.credentials}"

export NEXUS_CONSUMER_TOKEN
NEXUS_CONSUMER_TOKEN="$(printf '%s:%s' pub-consumer "$NEXUS_PUB_CONSUMER_PASSWORD" | base64 -w0)"

# Compose interpolates every service in the file, not only the selected profile,
# so the sidecar's TAILSCALE_AUTH_KEY has to resolve even when only the consumer
# is being run.
ENV_ARGS=()
[[ -f "$ROOT/.env" ]] && ENV_ARGS=(--env-file "$ROOT/.env")

exec docker compose \
  "${ENV_ARGS[@]}" \
  -f "$ROOT/nexus/docker-compose.yml" \
  --profile consumer \
  run --rm --build consumer "$@"
