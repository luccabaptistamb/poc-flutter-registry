#!/usr/bin/env bash
#
# Make Nexus trust the CA that signs intercepted TLS connections on the way out.
#
# On corporate networks a secure web gateway terminates outbound TLS and
# re-signs it with its own CA. The JVM does not trust that CA, so proxy
# repositories fail with:
#
#   javax.net.ssl.SSLHandshakeException: PKIX path building failed
#
# The host may be unaffected while containers are intercepted, so this is easy
# to misread as a Nexus problem. Verified on this machine: pub.dev is signed by
# Google Trust Services when seen from the host, and by "Akamai Enterprise (SL)"
# when seen from inside the container.
#
# This script reads the certificate actually presented to the container, adds
# the issuing CA to the Nexus truststore, and enables useTrustStore on the
# proxy repository, which Nexus requires for the truststore to be consulted at
# all.
#
# Usage:
#   nexus/trust-outbound-ca.sh [remote-host] [repository]

set -euo pipefail

REMOTE_HOST="${1:-pub.dev}"
REPOSITORY="${2:-pub-ingestion}"
NEXUS_URL="${NEXUS_URL:-http://localhost:8081}"
CONTAINER="${NEXUS_CONTAINER:-nexus}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS="$HERE/.credentials"

[[ -f "$CREDS" ]] || { echo "Missing $CREDS. Run nexus/bootstrap.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$CREDS"; set +a
AUTH=(-u "admin:${NEXUS_ADMIN_PASSWORD}")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Reading the certificate chain presented to the container for ${REMOTE_HOST}:443"

docker exec "$CONTAINER" sh -c \
  "timeout 20 openssl s_client -connect ${REMOTE_HOST}:443 -servername ${REMOTE_HOST} -showcerts </dev/null 2>/dev/null" \
  > "$WORK/chain.pem" || true

grep -q 'BEGIN CERTIFICATE' "$WORK/chain.pem" \
  || { echo "No certificate returned. Is outbound connectivity available at all?" >&2; exit 1; }

awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$WORK/chain.pem" > "$WORK/certs.pem"
csplit -sz -f "$WORK/cert-" -b '%02d.pem' "$WORK/certs.pem" '/BEGIN CERTIFICATE/' '{*}'

LEAF_ISSUER="$(openssl x509 -in "$WORK/cert-00.pem" -noout -issuer)"
echo "  leaf issuer: ${LEAF_ISSUER#issuer=}"

# Any certificate in the Nexus truststore acts as a trust anchor, so the
# intercepting intermediate is enough; its own root is usually not presented.
ANCHOR=""
for f in "$WORK"/cert-*.pem; do
  [[ "$f" == "$WORK/cert-00.pem" ]] && continue
  if openssl x509 -in "$f" -noout -text | grep -q 'CA:TRUE'; then
    ANCHOR="$f"
    break
  fi
done

if [[ -z "$ANCHOR" ]]; then
  echo "The chain has no CA certificate beyond the leaf." >&2
  echo "Either TLS is not being intercepted, or the gateway does not send its CA." >&2
  echo "In the latter case, export the CA from the OS trust store and add it in" >&2
  echo "Nexus under Security > SSL Certificates." >&2
  exit 1
fi

SUBJECT="$(openssl x509 -in "$ANCHOR" -noout -subject)"
echo "  trust anchor: ${SUBJECT#subject=}"
echo "  valid until:  $(openssl x509 -in "$ANCHOR" -noout -enddate | cut -d= -f2)"

# Verify the anchor is actually sufficient before changing Nexus.
docker cp "$ANCHOR" "$CONTAINER:/tmp/outbound-ca.pem" >/dev/null
if docker exec "$CONTAINER" sh -c \
    "timeout 20 curl -sS -o /dev/null --cacert /tmp/outbound-ca.pem https://${REMOTE_HOST}/" >/dev/null 2>&1; then
  echo "  verified: this anchor validates ${REMOTE_HOST}"
else
  echo "  warning: could not validate ${REMOTE_HOST} with this anchor; adding it anyway" >&2
fi

EXISTING="$(curl -sS "${AUTH[@]}" "$NEXUS_URL/service/rest/v1/security/ssl/truststore" \
  | jq -r --arg s "${SUBJECT#subject=}" '[.[] | select(.subjectCommonName as $c | $s | test($c))] | length')"

if [[ "${EXISTING:-0}" -gt 0 ]]; then
  echo "Certificate already present in the Nexus truststore."
else
  CODE="$(curl -sS -o "$WORK/add.json" -w '%{http_code}' -X POST "${AUTH[@]}" \
    -H 'Content-Type: application/x-pem-file' \
    --data-binary "@$ANCHOR" \
    "$NEXUS_URL/service/rest/v1/security/ssl/truststore")"
  [[ "$CODE" == "201" ]] \
    || { echo "Failed to add the certificate: HTTP $CODE $(cat "$WORK/add.json")" >&2; exit 1; }
  echo "Added the certificate to the Nexus truststore."
fi

# Nexus ignores its own truststore unless the repository opts in.
BODY="$(curl -sS "${AUTH[@]}" "$NEXUS_URL/service/rest/v1/repositories/pub/proxy/${REPOSITORY}" \
  | jq '.httpClient.connection = ((.httpClient.connection // {}) + {useTrustStore: true})')"

CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "${AUTH[@]}" \
  -H 'Content-Type: application/json' --data "$BODY" \
  "$NEXUS_URL/service/rest/v1/repositories/pub/proxy/${REPOSITORY}")"
[[ "$CODE" == "204" ]] \
  || { echo "Failed to enable useTrustStore on ${REPOSITORY}: HTTP $CODE" >&2; exit 1; }
echo "Enabled useTrustStore on '${REPOSITORY}'."

# A failed remote makes Nexus auto-block the repository and negatively cache the
# failure; both have to be cleared or the next request still looks broken.
curl -sS -o /dev/null -X POST "${AUTH[@]}" \
  "$NEXUS_URL/service/rest/v1/repositories/${REPOSITORY}/invalidate-cache"
echo "Invalidated the negative cache on '${REPOSITORY}'."

echo
echo "Done. If the repository was auto-blocked, the next request may still fail"
echo "until the block expires; retry for up to a minute."
