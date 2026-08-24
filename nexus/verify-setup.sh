#!/usr/bin/env bash
#
# Verify the local Nexus setup for the pub governance POC, mirroring the checks
# that verify-setup.yml performs against Cloudsmith, plus the two experiments
# that decide whether Community Edition is sufficient:
#
#   - can a package be promoted from the proxy into the hosted repository
#     without the Pro staging feature?
#   - is the archive's sha256 preserved by that promotion? Everything the
#     governance model claims about integrity depends on this.
#
# Usage:
#   nexus/verify-setup.sh
#
# Exit code is non-zero if any check fails. Secrets are never printed.

set -uo pipefail

NEXUS_URL="${NEXUS_URL:-http://localhost:8081}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS="$HERE/.credentials"

INGESTION_REPO="pub-ingestion"
PRODUCTION_REPO="pub-production"

# Small package with few dependencies, used for the promotion experiment.
PROMOTE_PACKAGE="${PROMOTE_PACKAGE:-path}"
# Never promoted, used for the negative test.
CANARY_PACKAGE="${CANARY_PACKAGE:-equatable}"

[[ -f "$CREDS" ]] || { echo "Missing $CREDS. Run nexus/bootstrap.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$CREDS"; set +a

ADMIN=(-u "admin:${NEXUS_ADMIN_PASSWORD}")
INGEST=(-u "ci-ingestion:${NEXUS_CI_INGESTION_PASSWORD}")
PROMOTE=(-u "ci-promotion:${NEXUS_CI_PROMOTION_PASSWORD}")
CONSUMER=(-u "pub-consumer:${NEXUS_PUB_CONSUMER_PASSWORD}")

PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$*"; }
head_() { printf '\n%s\n' "$*"; }

code() { curl -sS -o "${2:-/dev/null}" -w '%{http_code}' "${@:3}" "$1"; }

# ---------------------------------------------------------------------------
head_ "1. Instance and licence"
# ---------------------------------------------------------------------------

C="$(code "$NEXUS_URL/service/rest/v1/status")"
[[ "$C" == "200" ]] && ok "Nexus answers at $NEXUS_URL" || bad "Nexus status returned $C"

EULA="$(curl -sS "${ADMIN[@]}" "$NEXUS_URL/service/rest/v1/system/eula" | jq -r '.accepted')"
[[ "$EULA" == "true" ]] \
  && ok "Community Edition EULA accepted" \
  || bad "EULA not accepted; every repository request will return 403"

# ---------------------------------------------------------------------------
head_ "2. Authentication"
# ---------------------------------------------------------------------------

PKG_URL="$NEXUS_URL/repository/$INGESTION_REPO/api/packages/$PROMOTE_PACKAGE"

C="$(code "$PKG_URL")"
[[ "$C" == "401" ]] \
  && ok "Anonymous access is refused (HTTP 401)" \
  || bad "Anonymous request returned $C; expected 401. Is anonymous access still enabled?"

REALMS="$(curl -sS "${ADMIN[@]}" "$NEXUS_URL/service/rest/v1/security/realms/active" | jq -r '.[]' | paste -sd,)"
if grep -q 'PubToken' <<< "$REALMS"; then
  ok "PubToken realm is active ($REALMS)"
else
  bad "PubToken realm is NOT active ($REALMS); dart pub cannot authenticate"
fi

C="$(code "$PKG_URL" /dev/null "${INGEST[@]}")"
[[ "$C" == "200" ]] && ok "Basic auth works" || bad "Basic auth returned $C"

# This is the mechanism dart pub actually uses: it only ever sends
# `Authorization: Bearer <token>`, and the PubToken realm expects that token to
# be base64(user:password).
BEARER="$(printf '%s:%s' "ci-ingestion" "$NEXUS_CI_INGESTION_PASSWORD" | base64 -w0)"
C="$(code "$PKG_URL" /dev/null -H "Authorization: Bearer $BEARER")"
[[ "$C" == "200" ]] \
  && ok "Bearer base64(user:password) works — this is what dart pub token add stores" \
  || bad "Bearer token returned $C; dart pub will not be able to authenticate"

C="$(code "$PKG_URL" /dev/null -H "Authorization: Bearer $NEXUS_CI_INGESTION_PASSWORD")"
[[ "$C" == "401" ]] \
  && ok "Bearer with a raw password is refused, as expected" \
  || note "Bearer with a raw password returned $C"

# User tokens would let CI authenticate without the account password. Reported
# rather than asserted, because availability in Community Edition is the open
# question.
UT="$(code "$NEXUS_URL/service/rest/internal/current-user/user-token" /tmp/ut.json "${ADMIN[@]}")"
note "User token endpoint returned HTTP $UT $( [[ "$UT" == "200" ]] && echo '(available)' || echo '(not available in this edition)')"

# ---------------------------------------------------------------------------
head_ "3. Ingestion proxies pub.dev"
# ---------------------------------------------------------------------------

C="$(code "$PKG_URL" /tmp/pkg.json "${INGEST[@]}")"
if [[ "$C" == "200" ]]; then
  VERSIONS="$(jq -r '.versions | length' /tmp/pkg.json)"
  ok "Proxy serves pub.dev metadata for '$PROMOTE_PACKAGE' ($VERSIONS versions)"

  ARCHIVE_URL="$(jq -r '.latest.archive_url' /tmp/pkg.json)"
  if [[ "$ARCHIVE_URL" == *"/repository/$INGESTION_REPO/"* ]]; then
    ok "archive_url is rewritten to Nexus, so downloads stay inside the registry"
  else
    bad "archive_url points outside Nexus: $ARCHIVE_URL"
  fi
else
  bad "Proxy metadata returned $C. Check outbound TLS: nexus/trust-outbound-ca.sh"
fi

# ---------------------------------------------------------------------------
head_ "4. Production has no upstream"
# ---------------------------------------------------------------------------

C="$(code "$NEXUS_URL/repository/$PRODUCTION_REPO/api/packages/$CANARY_PACKAGE" /dev/null "${CONSUMER[@]}")"
[[ "$C" == "404" ]] \
  && ok "Production returns 404 for '$CANARY_PACKAGE', which was never promoted" \
  || bad "Production returned $C for an unpromoted package; expected 404"

# ---------------------------------------------------------------------------
head_ "5. Least privilege"
# ---------------------------------------------------------------------------

C="$(code "$NEXUS_URL/repository/$PRODUCTION_REPO/api/packages/$PROMOTE_PACKAGE" /dev/null "${INGEST[@]}")"
[[ "$C" == "403" || "$C" == "401" ]] \
  && ok "ci-ingestion cannot read production (HTTP $C)" \
  || bad "ci-ingestion reached production with HTTP $C; roles are too broad"

# ---------------------------------------------------------------------------
head_ "6. Promotion without Pro staging, and sha256 preservation"
# ---------------------------------------------------------------------------

VERSION="$(jq -r '.latest.version' /tmp/pkg.json 2>/dev/null)"
UPSTREAM_SHA="$(jq -r '.latest.archive_sha256' /tmp/pkg.json 2>/dev/null)"
ARCHIVE_URL="$(jq -r '.latest.archive_url' /tmp/pkg.json 2>/dev/null)"

if [[ -z "${VERSION:-}" || "$VERSION" == "null" ]]; then
  bad "Could not determine a version to promote; skipping the promotion experiment"
else
  note "Promoting ${PROMOTE_PACKAGE}@${VERSION}"

  TARBALL="/tmp/${PROMOTE_PACKAGE}-${VERSION}.tar.gz"
  C="$(code "$ARCHIVE_URL" "$TARBALL" "${INGEST[@]}" -L)"

  if [[ "$C" != "200" ]]; then
    bad "Could not download the archive from ingestion (HTTP $C)"
  else
    LOCAL_SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
    ok "Downloaded archive from ingestion ($(stat -c%s "$TARBALL") bytes)"

    if [[ "$LOCAL_SHA" == "$UPSTREAM_SHA" ]]; then
      ok "Downloaded bytes match the sha256 advertised by the proxy"
    else
      bad "sha256 mismatch on download: metadata=$UPSTREAM_SHA actual=$LOCAL_SHA"
    fi

    # Did the proxy persist the archive, or was it a pass-through? Without a
    # cached component there is nothing to promote.
    COMPONENTS="$(curl -sS "${ADMIN[@]}" \
      "$NEXUS_URL/service/rest/v1/components?repository=$INGESTION_REPO" \
      | jq -r --arg n "$PROMOTE_PACKAGE" '[.items[]?|select(.name==$n)]|length')"
    [[ "${COMPONENTS:-0}" -gt 0 ]] \
      && ok "Proxy cached the component ($COMPONENTS found), so there is something to promote" \
      || bad "Proxy did not persist the component; promotion has no source"

    # Upload into the hosted repository. The components API takes name and
    # version explicitly, so this does not depend on `dart pub publish` and its
    # pubspec validations, which could reject a third-party package.
    ALREADY="$(code "$NEXUS_URL/repository/$PRODUCTION_REPO/api/packages/$PROMOTE_PACKAGE" /tmp/prod.json "${PROMOTE[@]}")"

    if [[ "$ALREADY" == "200" ]] \
       && jq -e --arg v "$VERSION" '.versions[]?|select(.version==$v)' /tmp/prod.json >/dev/null; then
      note "${PROMOTE_PACKAGE}@${VERSION} is already in production; skipping upload (writePolicy is ALLOW_ONCE)"
    else
      C="$(code "$NEXUS_URL/service/rest/v1/components?repository=$PRODUCTION_REPO" /tmp/upload.txt \
        "${PROMOTE[@]}" -X POST \
        -F "pub.name=$PROMOTE_PACKAGE" \
        -F "pub.version=$VERSION" \
        -F "pub.asset=@$TARBALL")"

      if [[ "$C" == "204" || "$C" == "201" || "$C" == "200" ]]; then
        ok "Uploaded ${PROMOTE_PACKAGE}@${VERSION} into production (HTTP $C) without Pro staging"
      else
        bad "Upload failed (HTTP $C): $(head -c 300 /tmp/upload.txt)"
      fi
    fi

    # The decisive assertion: production must advertise the same sha256, because
    # pubspec.lock pins it and --enforce-lockfile validates it.
    C="$(code "$NEXUS_URL/repository/$PRODUCTION_REPO/api/packages/$PROMOTE_PACKAGE" /tmp/prod.json "${CONSUMER[@]}")"
    if [[ "$C" != "200" ]]; then
      bad "Production does not serve metadata for the promoted package (HTTP $C)"
    else
      PROD_SHA="$(jq -r --arg v "$VERSION" \
        '(.versions[]?|select(.version==$v)|.archive_sha256) // empty' /tmp/prod.json)"

      if [[ -z "$PROD_SHA" ]]; then
        bad "Production metadata has no entry for version $VERSION"
      elif [[ "$PROD_SHA" == "$UPSTREAM_SHA" ]]; then
        ok "sha256 preserved end to end: promotion keeps the artifact byte-identical"
        note "$UPSTREAM_SHA"
      else
        bad "sha256 CHANGED during promotion. --enforce-lockfile would fail."
        note "ingestion:  $UPSTREAM_SHA"
        note "production: $PROD_SHA"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
head_ "Summary"
# ---------------------------------------------------------------------------

printf '  %s passed, %s failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
