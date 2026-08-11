#!/usr/bin/env bash
#
# Promote Dart packages from the ingestion repository to the production
# repository, one package at a time, skipping anything already present.
#
# Usage:
#   promote-packages.sh <packages.tsv> [label]
#
# The TSV has one "name<TAB>version" per line.
#
# Required environment:
#   CLOUDSMITH_NAMESPACE
#   INGESTION_REPO
#   PRODUCTION_REPO
#
# Requires an authenticated `cloudsmith` CLI and `jq`.
#
# Not transactional: cloudsmith copy operates on one package at a time, so
# production can be temporarily incomplete. Idempotent, because packages that
# already exist in production are skipped.

set -euo pipefail

TSV="${1:?usage: promote-packages.sh <packages.tsv> [label]}"
LABEL="${2:-packages}"

: "${CLOUDSMITH_NAMESPACE:?CLOUDSMITH_NAMESPACE is required}"
: "${INGESTION_REPO:?INGESTION_REPO is required}"
: "${PRODUCTION_REPO:?PRODUCTION_REPO is required}"

[[ -s "$TSV" ]] || { echo "Empty or missing package list: $TSV" >&2; exit 1; }

# Echoes the package Unique ID once the artifact exists in <repo> and Cloudsmith
# reports synchronisation as complete.
#
# Exact-match anchors are mandatory: `name:foo` is a text search and could
# select the wrong artifact.
wait_for_package_sync() {
  local repo="$1"
  local name="$2"
  local version="$3"

  local query="format:dart AND name:^${name}$ AND version:^${version}$"
  local result=""
  local count=0
  local package_id=""
  local status=""

  for _ in $(seq 1 18); do
    result="$(
      cloudsmith ls pkg \
        "${CLOUDSMITH_NAMESPACE}/${repo}" \
        -q "$query" \
        -F json
    )"

    count="$(jq '.data | length' <<< "$result")"

    if [[ "$count" -gt 1 ]]; then
      echo "Duplicate exact package match: ${name}@${version} in ${repo}" >&2
      return 1
    fi

    if [[ "$count" -eq 1 ]]; then
      package_id="$(jq -r '.data[0].slug_perm // .data[0].slug' <<< "$result")"

      if jq -e '
        .data[0]
        | (.is_sync_completed == true) or ((.status_str // "") == "Completed")
      ' >/dev/null <<< "$result"; then
        printf '%s\n' "$package_id"
        return 0
      fi

      if jq -e '
        .data[0]
        | (.is_sync_failed == true) or ((.status_str // "") == "Failed")
      ' >/dev/null <<< "$result"; then
        echo "Package synchronisation failed: ${name}@${version} in ${repo}" >&2
        return 1
      fi

      # Fallback for CLI/API builds that do not expose the sync booleans in the
      # package listing.
      status="$(
        cloudsmith status \
          "${CLOUDSMITH_NAMESPACE}/${repo}/${package_id}" \
          2>/dev/null || true
      )"

      if grep -q 'Completed' <<< "$status"; then
        printf '%s\n' "$package_id"
        return 0
      fi

      if grep -q 'Failed' <<< "$status"; then
        echo "Package synchronisation failed: ${name}@${version} in ${repo}" >&2
        return 1
      fi
    fi

    sleep 10
  done

  echo "Timed out waiting for ${name}@${version} in ${repo}." >&2
  echo "Last listing payload:" >&2
  jq -c '.data' <<< "$result" >&2 || true
  return 1
}

summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

PROMOTED=0
SKIPPED=0
TOTAL="$(wc -l < "$TSV" | tr -d ' ')"

echo "Promoting ${TOTAL} ${LABEL} from ${INGESTION_REPO} to ${PRODUCTION_REPO}"

summary ""
summary "## Promotion result: ${LABEL}"
summary ""
summary '| package | version | action |'
summary '| --- | --- | --- |'

while IFS=$'\t' read -r NAME VERSION || [[ -n "${NAME:-}" ]]; do
  [[ -n "${NAME:-}" ]] || continue

  echo "::group::${NAME}@${VERSION}"

  PROD_QUERY="format:dart AND name:^${NAME}$ AND version:^${VERSION}$"

  PROD_RESULT="$(
    cloudsmith ls pkg \
      "${CLOUDSMITH_NAMESPACE}/${PRODUCTION_REPO}" \
      -q "$PROD_QUERY" \
      -F json
  )"

  PROD_COUNT="$(jq '.data | length' <<< "$PROD_RESULT")"

  if [[ "$PROD_COUNT" -gt 1 ]]; then
    echo "Duplicate package in production: ${NAME}@${VERSION}" >&2
    exit 1
  fi

  if [[ "$PROD_COUNT" -eq 1 ]]; then
    wait_for_package_sync "$PRODUCTION_REPO" "$NAME" "$VERSION" >/dev/null
    echo "Already available in production; skipping copy."
    summary "$(printf '| `%s` | `%s` | skipped (already present) |' "$NAME" "$VERSION")"
    SKIPPED=$((SKIPPED + 1))
    echo "::endgroup::"
    continue
  fi

  SOURCE_ID="$(wait_for_package_sync "$INGESTION_REPO" "$NAME" "$VERSION")"

  echo "Copying ${NAME}@${VERSION} (${SOURCE_ID}) to ${PRODUCTION_REPO}"

  cloudsmith copy \
    "${CLOUDSMITH_NAMESPACE}/${INGESTION_REPO}/${SOURCE_ID}" \
    "${PRODUCTION_REPO}"

  wait_for_package_sync "$PRODUCTION_REPO" "$NAME" "$VERSION" >/dev/null

  summary "$(printf '| `%s` | `%s` | copied |' "$NAME" "$VERSION")"
  PROMOTED=$((PROMOTED + 1))

  echo "::endgroup::"
done < "$TSV"

summary ""
summary "$(printf '**Copied:** %s  ' "$PROMOTED")"
summary "$(printf '**Skipped:** %s' "$SKIPPED")"

echo "Promotion finished. copied=${PROMOTED} skipped=${SKIPPED}"
