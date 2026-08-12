#!/bin/sh
# Keep every library already in the docs-mcp-server store up to date.
#
#   sync.sh              -> refresh every indexed library
#   sync.sh owner/repo   -> refresh just that one (used by the webhook receiver)
#
# The set of indexed libraries is managed through the web UI, and the store is
# the only place it lives. That is deliberate: this repo is public, so a
# checked-in list would publish exactly which repositories -- including private
# ones -- are being indexed. The trade-off is that the PVC is the sole record of
# what is indexed; there is nothing here to rebuild it from.
#
# "refresh" only works on a library that still has its stored scraper options,
# so we try it first and fall back to a full "scrape" against the sourceUrl the
# store reports. That keeps the job self-healing: a library whose options were
# lost gets re-indexed rather than silently going stale.
set -u

CLI="node --enable-source-maps /app/dist/index.js"

if [ -z "${DOCS_MCP_SERVER_URL:-}" ]; then
  echo "[sync] DOCS_MCP_SERVER_URL is not set" >&2
  exit 1
fi

# Pay the embedding model's load cost once, before any repo is touched. Without
# this the first pages of the run race a cold Ollama, time out, and get dropped
# with only a warning -- see warm-embeddings.mjs for why that is silent.
if ! node /etc/docs-mcp/warm-embeddings.mjs; then
  echo "[sync] aborting: embedding backend is not usable" >&2
  exit 1
fi

# One "<library>\x1f<version>\x1f<sourceUrl>" record per indexed version.
# Captured up front so the loops below are not reading from a pipe.
#
# The separator is the ASCII unit separator rather than a tab because `read`
# treats tab as IFS whitespace and collapses runs of it: an unversioned library
# emits an empty middle field, which with tabs would shift sourceUrl into the
# version column.
SEP=$(printf '\037')

list_versions() {
  # shellcheck disable=SC2086
  $CLI list --server-url "${DOCS_MCP_SERVER_URL}" --output json --quiet \
    | node /etc/docs-mcp/list-libraries.mjs
}

sync_one() {
  library="$1"
  label="$2"
  url="$3"

  if [ -n "${label}" ]; then
    echo "[sync] ${library}@${label}"
    set -- --version "${label}"
  else
    echo "[sync] ${library}"
    set --
  fi

  # shellcheck disable=SC2086
  if $CLI refresh "${library}" "$@" --server-url "${DOCS_MCP_SERVER_URL}"; then
    echo "[sync] refreshed '${library}'"
    return 0
  fi

  if [ -z "${url}" ]; then
    echo "[sync] FAILED to refresh '${library}' and it has no source URL to re-scrape" >&2
    return 1
  fi

  echo "[sync] refresh failed for '${library}', falling back to full scrape"
  # shellcheck disable=SC2086
  if $CLI scrape "${library}" "${url}" "$@" --server-url "${DOCS_MCP_SERVER_URL}"; then
    echo "[sync] scraped '${library}'"
    return 0
  fi

  echo "[sync] FAILED to index '${library}' from ${url}" >&2
  return 1
}

versions=$(list_versions) || {
  echo "[sync] could not enumerate the index" >&2
  exit 1
}

# Single-repo mode. The argument is a GitHub "owner/repo"; the library name is
# the repo half, matching how the UI names a library scraped from a repo URL.
# Requiring it to already be in the store is what gates the webhook: a delivery
# for anything unindexed is refused here rather than silently scraping it.
if [ "$#" -gt 0 ]; then
  target="${1##*/}"
  found=0
  rc=0

  # A library can hold several versions; refresh every one that matches.
  while IFS="${SEP}" read -r library label url; do
    [ "${library}" = "${target}" ] || continue
    found=1
    sync_one "${library}" "${label}" "${url}" || rc=1
  done <<EOF
${versions}
EOF

  if [ "${found}" -eq 0 ]; then
    echo "[sync] '${target}' is not indexed; refusing to scrape it" >&2
    exit 1
  fi

  exit "${rc}"
fi

rc=0
failed=""
count=0

# Read from a here-doc rather than a pipe: a `while` on the right of a pipe runs
# in a subshell, so anything tracked inside it is discarded when the loop ends.
# One bad library must not abort the run, but it must still fail the job -- a
# silent exit 0 would report a healthy index while it went stale.
while IFS="${SEP}" read -r library label url; do
  [ -n "${library}" ] || continue
  count=$((count + 1))

  if ! sync_one "${library}" "${label}" "${url}"; then
    rc=1
    failed="${failed} ${library}"
    echo "[sync] continuing after failure on ${library}" >&2
  fi
done <<EOF
${versions}
EOF

echo "[sync] processed ${count} library version(s)"

if [ "${rc}" -ne 0 ]; then
  echo "[sync] completed with failures:${failed}" >&2
fi

exit "${rc}"
