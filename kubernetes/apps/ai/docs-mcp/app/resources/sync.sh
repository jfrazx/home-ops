#!/bin/sh
# Index or update a GitHub repository in the docs-mcp-server store.
#
#   sync.sh              -> sync every repo listed in repos.txt
#   sync.sh owner/repo   -> sync a single repo (used by the webhook receiver)
#
# "refresh" only works on an already-indexed library, so we try it first and
# fall back to a full "scrape" when it fails. That makes the job self-healing:
# a brand new entry in repos.txt gets its initial index on the next run, and an
# existing one takes the cheap ETag path (304s skip chunking + embedding).
set -u

CLI="node --enable-source-maps /app/dist/index.js"
REPOS_FILE="${DOCS_MCP_REPOS_FILE:-/etc/docs-mcp/repos.txt}"

if [ -z "${DOCS_MCP_SERVER_URL:-}" ]; then
  echo "[sync] DOCS_MCP_SERVER_URL is not set" >&2
  exit 1
fi

sync_one() {
  repo="$1"
  library="${repo##*/}"
  url="https://github.com/${repo}"

  echo "[sync] ${repo} -> library '${library}'"

  # shellcheck disable=SC2086
  if $CLI refresh "${library}" --server-url "${DOCS_MCP_SERVER_URL}"; then
    echo "[sync] refreshed '${library}'"
    return 0
  fi

  echo "[sync] refresh failed for '${library}', falling back to full scrape"
  # shellcheck disable=SC2086
  if $CLI scrape "${library}" "${url}" --server-url "${DOCS_MCP_SERVER_URL}"; then
    echo "[sync] scraped '${library}'"
    return 0
  fi

  echo "[sync] FAILED to index '${library}' from ${url}" >&2
  return 1
}

if [ "$#" -gt 0 ]; then
  sync_one "$1"
  exit $?
fi

rc=0
# Strip comments and blank lines, then sync each entry. One bad repo must not
# abort the rest of the run, so failures are accumulated into the exit code.
sed -e 's/#.*$//' -e 's/[[:space:]]//g' "${REPOS_FILE}" \
  | grep -v '^$' \
  | while IFS= read -r repo; do
      sync_one "${repo}" || echo "[sync] continuing after failure on ${repo}" >&2
    done || rc=1

exit "${rc}"
