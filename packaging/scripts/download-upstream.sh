#!/usr/bin/env bash
# download-upstream.sh — Download the official Windows Claude Desktop installer
#
# Version detection NOTE: the claude.ai download endpoint does NOT include the
# app version in the redirect URL. Version is detected authoritatively by
# extract-windows.sh from the installer content. This script only downloads.
#
# Outputs (under UPSTREAM_DIR):
#   claude-setup.exe     — downloaded installer or copied local installer
#   upstream.json        — url, sha256, timestamp (version filled in by extract-windows.sh)
#   SHA256SUMS
#
# Usage: ./download-upstream.sh [--force] [--file /path/to/installer.exe]
# Env:   WORK_DIR, FORCE_DOWNLOAD, UPSTREAM_FILE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
UPSTREAM_DIR="${WORK_DIR}/upstream"
# Anthropic's current website links to the exe redirect endpoint with these query
# params, and Cloudflare now appears to require a browser-like request shape.
UPSTREAM_URL="https://claude.ai/api/desktop/win32/x64/exe/latest/redirect?utm_source=claude_code&utm_medium=docs"
DOWNLOAD_REFERER="https://claude.com/download"
DOWNLOAD_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"
UPSTREAM_FILE="${UPSTREAM_FILE:-}"

log() { printf '[download-upstream] %s\n' "$*" >&2; }
die() { printf '[download-upstream] ERROR: %s\n' "$*" >&2; exit 1; }

curl_download() {
    curl \
        -A "${DOWNLOAD_USER_AGENT}" \
        -e "${DOWNLOAD_REFERER}" \
        "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE_DOWNLOAD=1; shift ;;
        --file) UPSTREAM_FILE="$2"; shift 2 ;;
        --version) shift 2 ;;  # accepted but ignored — version comes from installer content
        *) die "Unknown argument: $1" ;;
    esac
done

command -v curl     >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

mkdir -p "${UPSTREAM_DIR}"

EXE_FILE="${UPSTREAM_DIR}/claude-setup.exe"

# --- obtain installer ---
if [[ -n "${UPSTREAM_FILE}" ]]; then
    [[ -f "${UPSTREAM_FILE}" ]] || die "Local installer not found: ${UPSTREAM_FILE}"
    log "Using local installer: ${UPSTREAM_FILE}"
    cp "${UPSTREAM_FILE}" "${EXE_FILE}.tmp"
    mv "${EXE_FILE}.tmp" "${EXE_FILE}"
    EFFECTIVE_URL="file://$(basename "${UPSTREAM_FILE}")"
    REDIRECT_URL="${UPSTREAM_FILE}"
elif [[ -f "${EXE_FILE}" && "${FORCE_DOWNLOAD}" != "1" ]]; then
    log "Already downloaded: ${EXE_FILE} (use --force to re-download)"
    EFFECTIVE_URL=$(curl_download -sL --max-redirs 10 -o /dev/null -w '%{url_effective}' \
        "${UPSTREAM_URL}" 2>/dev/null || echo "${UPSTREAM_URL}")
    REDIRECT_URL="${UPSTREAM_URL}"
else
    log "Downloading from: ${UPSTREAM_URL}"
    curl_download -L --fail --progress-bar "${UPSTREAM_URL}" -o "${EXE_FILE}.tmp" || \
        die "Download failed from ${UPSTREAM_URL}"
    mv "${EXE_FILE}.tmp" "${EXE_FILE}"
    log "Download complete: ${EXE_FILE}"
    EFFECTIVE_URL=$(curl_download -sL --max-redirs 10 -o /dev/null -w '%{url_effective}' \
        "${UPSTREAM_URL}" 2>/dev/null || echo "${UPSTREAM_URL}")
    REDIRECT_URL="${UPSTREAM_URL}"
fi

# --- checksum ---
SHA256=$(sha256sum "${EXE_FILE}" | awk '{print $1}')
printf '%s  claude-setup.exe\n' "${SHA256}" > "${UPSTREAM_DIR}/SHA256SUMS"
log "SHA256: ${SHA256}"

# --- metadata (version field filled in by extract-windows.sh) ---
cat > "${UPSTREAM_DIR}/upstream.json" <<EOF
{
  "version": "pending",
  "source_url": "${EFFECTIVE_URL}",
  "redirect_url": "${REDIRECT_URL}",
  "filename": "claude-setup.exe",
  "sha256": "${SHA256}",
  "downloaded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log "Done. upstream.json written (version will be detected by extract-windows.sh)."
