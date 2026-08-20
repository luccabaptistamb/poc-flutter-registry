#!/usr/bin/env bash
#
# Configure the local Nexus instance for the pub governance POC, mirroring the
# Cloudsmith design:
#
#   pub-ingestion    pub proxy    remote https://pub.dev
#   pub-production   pub hosted   no proxy, no group
#
# Deliberately no group repository: a group containing ingestion would let an
# unapproved package resolve by fallback, which is the exact bypass the design
# avoids.
#
# Idempotent: existing objects are left alone.
#
# Usage:
#   nexus/bootstrap.sh
#
# Credentials for the created accounts are written to nexus/.credentials, which
# is gitignored. Nothing secret is printed.

set -euo pipefail

NEXUS_URL="${NEXUS_URL:-http://localhost:8081}"
CONTAINER="${NEXUS_CONTAINER:-nexus}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS="$HERE/.credentials"

INGESTION_REPO="pub-ingestion"
PRODUCTION_REPO="pub-production"
REMOTE_URL="https://pub.dev"

log()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Admin credentials
# ---------------------------------------------------------------------------

# The generated password lives in the volume until the onboarding wizard runs.
# It is captured on first bootstrap and reused afterwards. The admin password is
# intentionally not rotated here: this is a local instance and rotating it would
# make the script non-idempotent for no benefit.
if [[ -f "$CREDS" ]] && grep -q '^NEXUS_ADMIN_PASSWORD=' "$CREDS"; then
  # shellcheck disable=SC1090
  ADMIN_PASSWORD="$(sed -n 's/^NEXUS_ADMIN_PASSWORD=//p' "$CREDS")"
else
  ADMIN_PASSWORD="$(docker exec "$CONTAINER" cat /nexus-data/admin.password 2>/dev/null || true)"
  [[ -n "$ADMIN_PASSWORD" ]] \
    || fail "Could not read /nexus-data/admin.password from container '$CONTAINER'. If onboarding already ran, put the password in $CREDS as NEXUS_ADMIN_PASSWORD=..."
  umask 077
  touch "$CREDS"
  printf 'NEXUS_ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD" >> "$CREDS"
fi

AUTH=(-u "admin:${ADMIN_PASSWORD}")

api() {
  # api <method> <path> [json-body]  -> echoes "<http_code>\n<body>"
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -o /tmp/nexus_api_out -w '%{http_code}' -X "$method" "${AUTH[@]}"
              -H 'Accept: application/json')
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  local code
  code="$(curl "${args[@]}" "${NEXUS_URL}${path}")"
  printf '%s\n' "$code"
  cat /tmp/nexus_api_out
}

http_code() { sed -n '1p' <<< "$1"; }
http_body() { sed '1d' <<< "$1"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

RESULT="$(api GET /service/rest/v1/status)"
[[ "$(http_code "$RESULT")" == "200" ]] \
  || fail "Nexus is not answering at $NEXUS_URL"

RESULT="$(api GET /service/rest/v1/status/writable)"
[[ "$(http_code "$RESULT")" =~ ^(200|204)$ ]] \
  || fail "Admin authentication failed. Check NEXUS_ADMIN_PASSWORD in $CREDS."

log "Nexus reachable and admin authentication works."

# ---------------------------------------------------------------------------
# 1. Community Edition EULA
# ---------------------------------------------------------------------------
# Community Edition refuses to serve repository content until the EULA is
# accepted; without this every request returns 403 with a message pointing at
# the onboarding wizard.
#
# This is a legal acceptance, so it is gated behind an explicit opt-in rather
# than happening silently as a side effect of "configure some repositories".

RESULT="$(api GET /service/rest/v1/system/eula)"
[[ "$(http_code "$RESULT")" == "200" ]] \
  || fail "Could not read EULA status: $(http_body "$RESULT")"

EULA_ACCEPTED="$(http_body "$RESULT" | jq -r '.accepted')"

if [[ "$EULA_ACCEPTED" == "true" ]]; then
  log "Community Edition EULA already accepted."
else
  if [[ "${NEXUS_ACCEPT_EULA:-}" != "yes" ]]; then
    fail "$(cat <<'MSG'
The Community Edition EULA has not been accepted, and Nexus will return 403 for
every repository request until it is.

This is a legal agreement, so this script will not accept it implicitly. Review:

  https://links.sonatype.com/products/nxrm/ce-eula

Then re-run with an explicit opt-in:

  NEXUS_ACCEPT_EULA=yes nexus/bootstrap.sh
MSG
)"
  fi

  DISCLAIMER="$(http_body "$RESULT" | jq -r '.disclaimer')"

  log "Accepting the Community Edition EULA (NEXUS_ACCEPT_EULA=yes was set)."
  log "  https://links.sonatype.com/products/nxrm/ce-eula"

  RESULT="$(api POST /service/rest/v1/system/eula "$(jq -n \
    --arg disclaimer "$DISCLAIMER" \
    '{ accepted: true, disclaimer: $disclaimer }')")"

  case "$(http_code "$RESULT")" in
    200|204) log "EULA accepted." ;;
    *) fail "Failed to accept the EULA: $(http_code "$RESULT") $(http_body "$RESULT")" ;;
  esac
fi

RESULT="$(api GET /service/rest/v1/security/anonymous)"

# ---------------------------------------------------------------------------
# 2. Anonymous access
# ---------------------------------------------------------------------------
# Nexus enables anonymous read by default. Left enabled, pub-production is not
# private and the negative test would be measuring the wrong thing. This is the
# equivalent of Cloudsmith's private visibility, except it is opt-out.

ANON_ENABLED="$(http_body "$RESULT" | jq -r '.enabled')"

if [[ "$ANON_ENABLED" == "true" ]]; then
  RESULT="$(api PUT /service/rest/v1/security/anonymous \
    '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}')"
  [[ "$(http_code "$RESULT")" == "200" ]] \
    || fail "Failed to disable anonymous access: $(http_body "$RESULT")"
  log "Anonymous access disabled."
else
  log "Anonymous access already disabled."
fi

# ---------------------------------------------------------------------------
# 3. Security realms
# ---------------------------------------------------------------------------
# The pub client only ever sends `Authorization: Bearer <token>`. Nexus decodes
# that token as base64(user:password), but only when the PubToken realm is
# active, and it is not active by default. Without this, dart pub gets 401 no
# matter how the token is configured.
#
# Note this is obfuscation, not tokenisation: the value is reversible, so it is
# equivalent to storing the password.

RESULT="$(api GET /service/rest/v1/security/realms/active)"
[[ "$(http_code "$RESULT")" == "200" ]] \
  || fail "Could not read active realms: $(http_body "$RESULT")"

ACTIVE_REALMS="$(http_body "$RESULT")"

if jq -e 'index("PubToken")' <<< "$ACTIVE_REALMS" >/dev/null; then
  log "PubToken realm already active."
else
  NEW_REALMS="$(jq -c '. + ["PubToken"]' <<< "$ACTIVE_REALMS")"
  RESULT="$(api PUT /service/rest/v1/security/realms/active "$NEW_REALMS")"
  case "$(http_code "$RESULT")" in
    200|204) log "Activated the PubToken realm (now: $(jq -r 'join(",")' <<< "$NEW_REALMS"))" ;;
    *) fail "Failed to activate the PubToken realm: $(http_code "$RESULT") $(http_body "$RESULT")" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 4. Repositories
# ---------------------------------------------------------------------------

repo_exists() {
  local name="$1" result
  result="$(api GET "/service/rest/v1/repositories/${name}")"
  [[ "$(http_code "$result")" == "200" ]]
}

if repo_exists "$INGESTION_REPO"; then
  log "Repository '$INGESTION_REPO' already exists."
else
  RESULT="$(api POST /service/rest/v1/repositories/pub/proxy "$(jq -n \
    --arg name "$INGESTION_REPO" \
    --arg remote "$REMOTE_URL" \
    '{
      name: $name,
      online: true,
      storage: { blobStoreName: "default", strictContentTypeValidation: true },
      proxy: { remoteUrl: $remote, contentMaxAge: -1, metadataMaxAge: 1440 },
      # A 24h negative cache (the Nexus default) means a transient outbound
      # failure keeps answering 404 for a day. Short TTL keeps the POC
      # debuggable and lets a newly published upstream version show up.
      negativeCache: { enabled: true, timeToLive: 5 },
      httpClient: {
        blocked: false,
        autoBlock: true,
        # Required for Nexus to use certificates from its own truststore when
        # connecting outbound. Without it the truststore is ignored, which
        # matters on networks that intercept TLS.
        connection: { useTrustStore: true }
      }
    }')")"
  [[ "$(http_code "$RESULT")" == "201" ]] \
    || fail "Failed to create '$INGESTION_REPO': $(http_code "$RESULT") $(http_body "$RESULT")"
  log "Created pub proxy '$INGESTION_REPO' -> $REMOTE_URL"
fi

if repo_exists "$PRODUCTION_REPO"; then
  log "Repository '$PRODUCTION_REPO' already exists."
else
  # writePolicy ALLOW_ONCE permits the first deploy of a version and refuses a
  # redeploy. An approved artifact must not be silently replaced, and the
  # promotion already skips versions that exist.
  RESULT="$(api POST /service/rest/v1/repositories/pub/hosted "$(jq -n \
    --arg name "$PRODUCTION_REPO" \
    '{
      name: $name,
      online: true,
      storage: {
        blobStoreName: "default",
        strictContentTypeValidation: true,
        writePolicy: "ALLOW_ONCE"
      }
    }')")"
  [[ "$(http_code "$RESULT")" == "201" ]] \
    || fail "Failed to create '$PRODUCTION_REPO': $(http_code "$RESULT") $(http_body "$RESULT")"
  log "Created pub hosted '$PRODUCTION_REPO' (no proxy, writePolicy ALLOW_ONCE)"
fi

# ---------------------------------------------------------------------------
# 5. Privileges
# ---------------------------------------------------------------------------

create_privilege() {
  local name="$1" repo="$2" description="$3" actions="$4" result

  result="$(api GET "/service/rest/v1/security/privileges/${name}")"
  if [[ "$(http_code "$result")" == "200" ]]; then
    log "Privilege '$name' already exists."
    return 0
  fi

  result="$(api POST /service/rest/v1/security/privileges/repository-view "$(jq -n \
    --arg name "$name" \
    --arg repo "$repo" \
    --arg description "$description" \
    --argjson actions "$actions" \
    '{ name: $name, description: $description, actions: $actions,
       format: "pub", repository: $repo }')")"

  [[ "$(http_code "$result")" == "201" ]] \
    || fail "Failed to create privilege '$name': $(http_code "$result") $(http_body "$result")"
  log "Created privilege '$name'"
}

create_privilege "pub-ingestion-read"  "$INGESTION_REPO" \
  "Read pub-ingestion" '["BROWSE","READ"]'
create_privilege "pub-ingestion-write" "$INGESTION_REPO" \
  "Write pub-ingestion" '["BROWSE","READ","EDIT","ADD"]'
create_privilege "pub-production-read"  "$PRODUCTION_REPO" \
  "Read pub-production" '["BROWSE","READ"]'
create_privilege "pub-production-write" "$PRODUCTION_REPO" \
  "Write pub-production" '["BROWSE","READ","EDIT","ADD"]'

# ---------------------------------------------------------------------------
# 6. Roles
# ---------------------------------------------------------------------------
# Least privilege, matching the two-identity split the workflows already carry
# as separate variables:
#
#   ci-ingestion   write on ingestion, NOTHING on production
#   ci-promotion   read on ingestion, write on production
#   pub-consumer   read on production only

create_role() {
  local id="$1" description="$2" privileges="$3" result

  result="$(api GET "/service/rest/v1/security/roles/${id}")"
  if [[ "$(http_code "$result")" == "200" ]]; then
    log "Role '$id' already exists."
    return 0
  fi

  result="$(api POST /service/rest/v1/security/roles "$(jq -n \
    --arg id "$id" \
    --arg description "$description" \
    --argjson privileges "$privileges" \
    '{ id: $id, name: $id, description: $description, privileges: $privileges, roles: [] }')")"

  [[ "$(http_code "$result")" == "200" || "$(http_code "$result")" == "201" ]] \
    || fail "Failed to create role '$id': $(http_code "$result") $(http_body "$result")"
  log "Created role '$id'"
}

create_role "ci-ingestion" "CI: cache packages from pub.dev into ingestion" \
  '["pub-ingestion-write"]'
create_role "ci-promotion" "CI: read ingestion, write production" \
  '["pub-ingestion-read","pub-production-write"]'
create_role "pub-consumer" "Developers and builds: read production only" \
  '["pub-production-read"]'

# ---------------------------------------------------------------------------
# 7. Users
# ---------------------------------------------------------------------------

random_password() {
  # Nexus rejects trivial passwords; keep it long and alphanumeric to avoid
  # quoting problems in URLs and shell.
  head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24
}

create_user() {
  local user_id="$1" role="$2" result password var

  var="NEXUS_$(tr 'a-z-' 'A-Z_' <<< "$user_id")_PASSWORD"

  result="$(api GET "/service/rest/v1/security/users?userId=${user_id}")"
  if [[ "$(http_code "$result")" == "200" ]] \
     && [[ "$(http_body "$result" | jq -r --arg u "$user_id" '[.[]|select(.userId==$u)]|length')" != "0" ]]; then
    if grep -q "^${var}=" "$CREDS"; then
      log "User '$user_id' already exists and its password is recorded."
    else
      log "User '$user_id' exists but its password is NOT in $CREDS."
      log "  Reset it in the UI or delete the user and re-run this script."
    fi
    return 0
  fi

  password="$(random_password)"

  result="$(api POST /service/rest/v1/security/users "$(jq -n \
    --arg id "$user_id" \
    --arg pw "$password" \
    --arg role "$role" \
    '{ userId: $id, firstName: "POC", lastName: $id,
       emailAddress: ($id + "@example.invalid"),
       password: $pw, status: "active", roles: [$role] }')")"

  [[ "$(http_code "$result")" == "200" || "$(http_code "$result")" == "201" ]] \
    || fail "Failed to create user '$user_id': $(http_code "$result") $(http_body "$result")"

  umask 077
  printf '%s=%s\n' "$var" "$password" >> "$CREDS"
  log "Created user '$user_id' with role '$role' (password in nexus/.credentials)"
}

create_user "ci-ingestion" "ci-ingestion"
create_user "ci-promotion" "ci-promotion"
create_user "pub-consumer" "pub-consumer"

# ---------------------------------------------------------------------------
# 8. Base URL
# ---------------------------------------------------------------------------
# Nexus derives archive_url from the incoming request, so behind a proxy it can
# advertise an address the client cannot reach. The pub client then gets correct
# metadata pointing at unreachable files.
#
# Worse, the host ends up recorded in every pubspec.lock entry, so it is part of
# the approved evidence: changing it later invalidates every approved lockfile.
#
# Only set when NEXUS_PUBLIC_URL is given, so the local-only setup keeps working
# without it.

if [[ -n "${NEXUS_PUBLIC_URL:-}" ]]; then
  PUBLIC_URL="${NEXUS_PUBLIC_URL%/}"

  RESULT="$(api GET /service/rest/v1/capabilities)"
  [[ "$(http_code "$RESULT")" == "200" ]] \
    || fail "Could not list capabilities: $(http_body "$RESULT")"

  BASEURL_ID="$(http_body "$RESULT" | jq -r '.[] | select(.type == "baseurl") | .id' | head -1)"

  # The field is `properties`, a plain string map, not `attributes`: with the
  # wrong name the API answers 400 "url must not be blank".
  BASEURL_BODY="$(jq -n --arg url "$PUBLIC_URL" \
    '{ type: "baseurl", enabled: true,
       notes: "Set by nexus/bootstrap.sh so archive_url uses the external hostname",
       properties: { url: $url } }')"

  if [[ -n "$BASEURL_ID" ]]; then
    # The id must be repeated inside the body. Without it the API answers 500
    # with a NullPointerException instead of a validation error.
    RESULT="$(api PUT "/service/rest/v1/capabilities/${BASEURL_ID}" \
      "$(jq --arg id "$BASEURL_ID" '. + { id: $id }' <<< "$BASEURL_BODY")")"
  else
    RESULT="$(api POST /service/rest/v1/capabilities "$BASEURL_BODY")"
  fi

  case "$(http_code "$RESULT")" in
    200|201|204)
      log "Base URL set to ${PUBLIC_URL}"
      log "  Restart Nexus for this to reach the pub metadata. Until then the"
      log "  generated archive_url keeps the old host, even for packages that"
      log "  were never requested before:"
      log "    docker compose -f nexus/docker-compose.yml restart nexus"
      ;;
    *) fail "Failed to set the Base URL: $(http_code "$RESULT") $(http_body "$RESULT")" ;;
  esac
else
  log "NEXUS_PUBLIC_URL not set; leaving the Base URL derived from the request."
  log "  Required once Nexus is served through a tunnel, otherwise archive_url"
  log "  points at an address the runner cannot reach."
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------

log ""
log "Bootstrap complete."
log ""
log "  pub proxy   ${NEXUS_URL}/repository/${INGESTION_REPO}/"
log "  pub hosted  ${NEXUS_URL}/repository/${PRODUCTION_REPO}/"
log ""
log "  credentials: nexus/.credentials (gitignored)"
log ""
log "If outbound TLS is intercepted on this network, run:"
log "  nexus/trust-outbound-ca.sh"
log ""
log "Then run nexus/verify-setup.sh."
