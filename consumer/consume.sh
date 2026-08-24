#!/usr/bin/env bash
#
# Resolves the sample app against pub-production only, as a developer machine
# would, and then proves the boundary holds by asking for something that was
# never promoted.
#
# Usage (through compose, which supplies the environment):
#   docker compose --env-file .env -f nexus/docker-compose.yml \
#     --profile consumer run --rm consumer [resolve|negative|shell]
#
# Required environment:
#   NEXUS_PRODUCTION_URL   https://<host>/repository/pub-production/
#   NEXUS_TOKEN            base64(user:password) for an identity that can read
#                          production
#
# Optional:
#   https_proxy            how to reach the tailnet from a container that is not
#                          itself a tailnet node

set -euo pipefail

MODE="${1:-resolve}"

: "${NEXUS_PRODUCTION_URL:?NEXUS_PRODUCTION_URL is required}"
: "${NEXUS_TOKEN:?NEXUS_TOKEN is required}"

# An empty cache on every run: with a warm cache a successful resolution would
# prove nothing about what production actually serves.
export PUB_CACHE="/home/dev/.pub-cache-run"
rm -rf "$PUB_CACHE"
mkdir -p "$PUB_CACHE"

export PUB_HOSTED_URL="$NEXUS_PRODUCTION_URL"

echo "SDK:             $(flutter --version | head -1)"
echo "PUB_HOSTED_URL:  $PUB_HOSTED_URL"
echo "proxy:           ${https_proxy:-none}"
echo

# Stored by reference: pub records the env var name, not the value. Refuses a
# non-HTTPS URL, which is why this goes through the tailnet hostname and not the
# container-local http://nexus:8081.
dart pub token add "$PUB_HOSTED_URL" --env-var NEXUS_TOKEN

case "$MODE" in

  resolve)
    echo "::: flutter pub get against production only"
    flutter pub get

    echo
    echo "::: what was actually downloaded"
    find "$PUB_CACHE/hosted" -maxdepth 2 -mindepth 2 -type d \
      | sed 's#.*/##' | sort | sed 's/^/  /'

    echo
    echo "::: the lockfile records production as the source"
    grep -m1 -A1 'url:' pubspec.lock || true

    echo
    echo "::: flutter analyze, to exercise the toolchain from production"
    flutter analyze --no-pub || true

    echo
    echo "::: resolving again with --enforce-lockfile (content hashes must match)"
    flutter pub get --enforce-lockfile

    echo
    echo "OK: production served the whole approved graph, hashes included."
    ;;

  negative)
    # The boundary: a package that exists on pub.dev but was never promoted.
    UNAPPROVED="${UNAPPROVED_PACKAGE:-equatable}"

    echo "::: asking for '${UNAPPROVED}', which was never approved"

    cp pubspec.yaml /tmp/pubspec.yaml.bak
    printf '  %s: any\n' "$UNAPPROVED" >> pubspec.yaml

    if flutter pub get 2>&1 | tee /tmp/negative.log; then
      cp /tmp/pubspec.yaml.bak pubspec.yaml
      echo
      echo "FAIL: production resolved '${UNAPPROVED}'." >&2
      exit 1
    fi

    cp /tmp/pubspec.yaml.bak pubspec.yaml

    if ! grep -q "$UNAPPROVED" /tmp/negative.log; then
      echo
      echo "Resolution failed, but not because of '${UNAPPROVED}'; inconclusive." >&2
      exit 1
    fi

    echo
    echo "OK: production refused '${UNAPPROVED}'. Unapproved means unavailable."
    ;;

  shell)
    exec bash
    ;;

  *)
    echo "Unknown mode: $MODE (expected resolve, negative or shell)" >&2
    exit 1
    ;;
esac
