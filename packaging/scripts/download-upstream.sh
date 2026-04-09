#!/usr/bin/env bash
# download-upstream.sh — Download the official Windows Claude Desktop installer
#
# Version detection NOTE: the claude.ai download endpoint does NOT include the
# app version in the redirect URL. Version is detected authoritatively by
# extract-windows.sh from the installer content. This script only downloads.
#
# Outputs (under UPSTREAM_DIR):
#   claude-setup.exe     — downloaded installer (canonical name)
#   upstream.json        — url, sha256, timestamp (version filled in by extract-windows.sh)
#   SHA256SUMS
#
# Usage: ./download-upstream.sh [--force]
# Env:   WORK_DIR, FORCE_DOWNLOAD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
UPSTREAM_DIR="${WORK_DIR}/upstream"
UPSTREAM_URL="https://claude.ai/api/desktop/win32/x64/setup/latest/redirect"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"

log() { printf '[download-upstream] %s\n' "$*" >&2; }
die() { printf '[download-upstream] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE_DOWNLOAD=1; shift ;;
        --version) shift 2 ;;  # accepted but ignored — version comes from installer content
        *) die "Unknown argument: $1" ;;
    esac
done

command -v curl     >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

mkdir -p "${UPSTREAM_DIR}"

EXE_FILE="${UPSTREAM_DIR}/claude-setup.exe"

# --- download ---
if [[ -f "${EXE_FILE}" && "${FORCE_DOWNLOAD}" != "1" ]]; then
    log "Already downloaded: ${EXE_FILE} (use --force to re-download)"
else
    log "Downloading from: ${UPSTREAM_URL}"
    curl -L --fail --progress-bar "${UPSTREAM_URL}" -o "${EXE_FILE}.tmp" || \
        die "Download failed from ${UPSTREAM_URL}"
    mv "${EXE_FILE}.tmp" "${EXE_FILE}"
    log "Download complete: ${EXE_FILE}"
fi

# --- checksum ---
SHA256=$(sha256sum "${EXE_FILE}" | awk '{print $1}')
printf '%s  claude-setup.exe\n' "${SHA256}" > "${UPSTREAM_DIR}/SHA256SUMS"
log "SHA256: ${SHA256}"

# --- resolve effective URL (informational only, not used for version) ---
EFFECTIVE_URL=$(curl -sL --max-redirs 10 -o /dev/null -w '%{url_effective}' \
    "${UPSTREAM_URL}" 2>/dev/null || echo "${UPSTREAM_URL}")

# --- metadata (version field filled in by extract-windows.sh) ---
cat > "${UPSTREAM_DIR}/upstream.json" <<EOF
{
  "version": "pending",
  "source_url": "${EFFECTIVE_URL}",
  "redirect_url": "${UPSTREAM_URL}",
  "filename": "claude-setup.exe",
  "sha256": "${SHA256}",
  "downloaded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log "Done. upstream.json written (version will be detected by extract-windows.sh)."
