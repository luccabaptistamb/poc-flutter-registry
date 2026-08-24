#!/usr/bin/env bash
#
# Promote Dart packages from the ingestion repository to the production
# repository on Sonatype Nexus, one package at a time, skipping anything
# already present.
#
# Usage:
#   nexus-promote-packages.sh <packages.tsv> [label]
#
# The TSV has one "name<TAB>version" per line.
#
# Required environment:
#   NEXUS_BASE_URL     e.g. http://localhost:8081
#   INGESTION_REPO     pub proxy repository name
#   PRODUCTION_REPO    pub hosted repository name
#   NEXUS_TOKEN        base64(user:password) for an identity with read on
#                      ingestion and write on production
#
# NEXUS_TOKEN is the same value `dart pub token add` stores, and it is sent here
# as `Authorization: Basic`, not `Bearer`. The PubToken realm that accepts Bearer
# only covers the /repository endpoints: the /service/rest components API answers
# 403 to a Bearer token and 200 to the identical value sent as Basic. The token
# is literally base64(user:password), so one value serves both.
#
# Requires `curl`, `jq` and `sha256sum`.
#
# Same interface as promote-packages.sh (the Cloudsmith version) so the
# workflows do not need to know which registry is behind it. Differences that
# come from Nexus Community Edition:
#
#   - there is no server-side copy: the artifact is downloaded from the proxy
#     and uploaded to the hosted repository. The bytes are preserved, so the
#     sha256 pinned in pubspec.lock still matches;
#   - the upload is synchronous, so there is no synchronisation to wait for;
#   - the sha256 is verified on download AND after the upload, instead of being
#     trusted to a copy operation;
#   - the hosted repository uses writePolicy ALLOW_ONCE, so re-uploading an
#     existing version fails. Skipping what already exists is what keeps this
#     idempotent, not an optimisation.
#
# Not transactional: production can be temporarily incomplete while this runs.

set -euo pipefail

TSV="${1:?usage: nexus-promote-packages.sh <packages.tsv> [label]}"
LABEL="${2:-packages}"

: "${NEXUS_BASE_URL:?NEXUS_BASE_URL is required}"
: "${INGESTION_REPO:?INGESTION_REPO is required}"
: "${PRODUCTION_REPO:?PRODUCTION_REPO is required}"
: "${NEXUS_TOKEN:?NEXUS_TOKEN is required}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

[[ -s "$TSV" ]] || { echo "Empty or missing package list: $TSV" >&2; exit 1; }

BASE_URL="${NEXUS_BASE_URL%/}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# The token is passed to curl through a config file instead of argv, so it does
# not show up in the process list.
CURL_CONFIG="$WORKDIR/curl.conf"
umask 077
cat > "$CURL_CONFIG" <<EOF
header = "Authorization: Basic ${NEXUS_TOKEN}"
EOF

# request <method> <url> <output-file> [extra curl args...] -> echoes HTTP code
request() {
  local method="$1" url="$2" out="$3"
  shift 3
  curl -sS --config "$CURL_CONFIG" \
    -X "$method" \
    -o "$out" \
    -w '%{http_code}' \
    --max-time 300 \
    "$@" \
    "$url"
}

# Retried because the ingestion repository is a proxy: the first request for a
# package can go all the way to pub.dev, and a transient outbound failure would
# otherwise abort the whole promotion.
request_with_retry() {
  local method="$1" url="$2" out="$3"
  shift 3
  local code="" attempt

  for attempt in 1 2 3; do
    code="$(request "$method" "$url" "$out" "$@" || true)"
    case "$code" in
      2*|404) printf '%s\n' "$code"; return 0 ;;
    esac
    [[ "$attempt" -lt 3 ]] && sleep $((attempt * 5))
  done

  printf '%s\n' "${code:-000}"
  return 0
}

package_metadata_url() {
  printf '%s/repository/%s/api/packages/%s\n' "$BASE_URL" "$1" "$2"
}

# Echoes the sha256 that <repo> advertises for <name>@<version>, or nothing if
# the version is not served. A non-404 failure is fatal: silently treating it as
# "absent" would try to upload over an existing artifact.
advertised_sha256() {
  local repo="$1" name="$2" version="$3"
  local out="$WORKDIR/metadata.json" code

  code="$(request_with_retry GET "$(package_metadata_url "$repo" "$name")" "$out")"

  case "$code" in
    200) ;;
    404) return 0 ;;
    *)
      echo "Unexpected HTTP $code reading ${name} metadata from ${repo}" >&2
      return 1
      ;;
  esac

  jq -r --arg v "$version" \
    '(.versions[]? | select(.version == $v) | .archive_sha256) // empty' "$out"
}

summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

PROMOTED=0
SKIPPED=0
TOTAL="$(grep -cve '^[[:space:]]*$' "$TSV" || true)"

echo "Promoting ${TOTAL} ${LABEL} from ${INGESTION_REPO} to ${PRODUCTION_REPO}"
echo "Nexus: ${BASE_URL}"

summary ""
summary "## Promotion result: ${LABEL}"
summary ""
summary '| package | version | action |'
summary '| --- | --- | --- |'

while IFS=$'\t' read -r NAME VERSION || [[ -n "${NAME:-}" ]]; do
  [[ -n "${NAME:-}" ]] || continue
  [[ -n "${VERSION:-}" ]] || { echo "Missing version for '${NAME}' in ${TSV}" >&2; exit 1; }

  echo "::group::${NAME}@${VERSION}"

  PROD_SHA="$(advertised_sha256 "$PRODUCTION_REPO" "$NAME" "$VERSION")"

  if [[ -n "$PROD_SHA" ]]; then
    echo "Already available in production; skipping upload."
    summary "$(printf '| `%s` | `%s` | skipped (already present) |' "$NAME" "$VERSION")"
    SKIPPED=$((SKIPPED + 1))
    echo "::endgroup::"
    continue
  fi

  # Resolve the archive through the ingestion repository. The URL is taken from
  # the proxy's own metadata rather than constructed, so the download stays
  # inside the registry even if Nexus changes its archive layout.
  INGEST_METADATA="$WORKDIR/ingestion.json"
  CODE="$(request_with_retry GET "$(package_metadata_url "$INGESTION_REPO" "$NAME")" "$INGEST_METADATA")"

  if [[ "$CODE" != "200" ]]; then
    echo "Could not read ${NAME} metadata from ${INGESTION_REPO} (HTTP $CODE)" >&2
    exit 1
  fi

  ARCHIVE_URL="$(jq -r --arg v "$VERSION" \
    '(.versions[]? | select(.version == $v) | .archive_url) // empty' "$INGEST_METADATA")"
  INGEST_SHA="$(jq -r --arg v "$VERSION" \
    '(.versions[]? | select(.version == $v) | .archive_sha256) // empty' "$INGEST_METADATA")"

  if [[ -z "$ARCHIVE_URL" || -z "$INGEST_SHA" ]]; then
    echo "${NAME}@${VERSION} is not served by ${INGESTION_REPO}" >&2
    exit 1
  fi

  TARBALL="$WORKDIR/${NAME}-${VERSION}.tar.gz"
  CODE="$(request_with_retry GET "$ARCHIVE_URL" "$TARBALL" -L)"

  if [[ "$CODE" != "200" ]]; then
    echo "Could not download ${NAME}@${VERSION} from ${INGESTION_REPO} (HTTP $CODE)" >&2
    exit 1
  fi

  LOCAL_SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"

  if [[ "$LOCAL_SHA" != "$INGEST_SHA" ]]; then
    echo "sha256 mismatch downloading ${NAME}@${VERSION}" >&2
    echo "  metadata: ${INGEST_SHA}" >&2
    echo "  actual:   ${LOCAL_SHA}" >&2
    exit 1
  fi

  echo "Downloaded ${NAME}@${VERSION} ($(stat -c%s "$TARBALL") bytes, sha256 verified)"

  # The components API takes name and version explicitly, so promotion does not
  # depend on `dart pub publish` and its pubspec validations, which can reject a
  # third-party package.
  UPLOAD_OUT="$WORKDIR/upload.txt"
  CODE="$(request POST \
    "${BASE_URL}/service/rest/v1/components?repository=${PRODUCTION_REPO}" \
    "$UPLOAD_OUT" \
    -F "pub.name=${NAME}" \
    -F "pub.version=${VERSION}" \
    -F "pub.asset=@${TARBALL}")"

  case "$CODE" in
    200|201|204) echo "Uploaded ${NAME}@${VERSION} to ${PRODUCTION_REPO} (HTTP $CODE)" ;;
    *)
      echo "Upload of ${NAME}@${VERSION} failed (HTTP $CODE): $(head -c 500 "$UPLOAD_OUT")" >&2
      exit 1
      ;;
  esac

  # The decisive check: production must advertise the same sha256, because
  # pubspec.lock pins it and --enforce-lockfile validates it.
  PROD_SHA="$(advertised_sha256 "$PRODUCTION_REPO" "$NAME" "$VERSION")"

  if [[ -z "$PROD_SHA" ]]; then
    echo "${PRODUCTION_REPO} does not serve ${NAME}@${VERSION} after the upload" >&2
    exit 1
  fi

  if [[ "$PROD_SHA" != "$INGEST_SHA" ]]; then
    echo "sha256 changed during promotion of ${NAME}@${VERSION}" >&2
    echo "  ingestion:  ${INGEST_SHA}" >&2
    echo "  production: ${PROD_SHA}" >&2
    exit 1
  fi

  echo "sha256 preserved: ${PROD_SHA}"

  summary "$(printf '| `%s` | `%s` | promoted |' "$NAME" "$VERSION")"
  PROMOTED=$((PROMOTED + 1))

  rm -f "$TARBALL"
  echo "::endgroup::"
done < "$TSV"

summary ""
summary "$(printf '**Promoted:** %s  ' "$PROMOTED")"
summary "$(printf '**Skipped:** %s' "$SKIPPED")"

echo "Promotion finished. promoted=${PROMOTED} skipped=${SKIPPED}"
