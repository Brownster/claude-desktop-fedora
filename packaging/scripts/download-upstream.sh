#!/usr/bin/env bash
# download-upstream.sh — Download the official Windows Claude Desktop installer
#
# Outputs (under UPSTREAM_DIR):
#   Claude-<version>-x64.exe
#   upstream.json
#   SHA256SUMS
#
# Usage: ./download-upstream.sh [--version X.Y.Z]
# Env:   WORK_DIR, ARCH, FORCE_DOWNLOAD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
UPSTREAM_DIR="${WORK_DIR}/upstream"
UPSTREAM_URL="https://claude.ai/api/desktop/win32/x64/setup/latest/redirect"
ARCH="${ARCH:-x64}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"
FIXED_VERSION=""

log()  { printf '[download-upstream] %s\n' "$*" >&2; }
die()  { printf '[download-upstream] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[download-upstream] %s\n' "$*"; }

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) FIXED_VERSION="$2"; shift 2 ;;
        --force)   FORCE_DOWNLOAD=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v curl  >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

mkdir -p "${UPSTREAM_DIR}"

# --- resolve final URL ---
log "Resolving upstream URL: ${UPSTREAM_URL}"
FINAL_URL=$(curl -sI -L --max-redirs 10 "${UPSTREAM_URL}" -o /dev/null -w '%{url_effective}')
[[ -z "${FINAL_URL}" ]] && die "Failed to resolve upstream URL"
log "Resolved to: ${FINAL_URL}"

# --- detect version ---
VERSION="${FIXED_VERSION}"
if [[ -z "${VERSION}" ]]; then
    VERSION=$(echo "${FINAL_URL}" | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
fi
if [[ -z "${VERSION}" ]]; then
    # Try headers
    VERSION=$(curl -sI "${UPSTREAM_URL}" | grep -i 'content-disposition' | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
fi
[[ -z "${VERSION}" ]] && die "Could not detect version. Use --version X.Y.Z to override."

log "Version: ${VERSION}"

EXE_FILE="${UPSTREAM_DIR}/Claude-${VERSION}-x64.exe"

# --- download ---
if [[ -f "${EXE_FILE}" && "${FORCE_DOWNLOAD}" != "1" ]]; then
    log "Already downloaded: ${EXE_FILE} (use --force to re-download)"
else
    log "Downloading -> ${EXE_FILE}"
    curl -L --progress-bar --fail "${FINAL_URL}" -o "${EXE_FILE}.tmp"
    mv "${EXE_FILE}.tmp" "${EXE_FILE}"
    log "Download complete."
fi

# --- checksum ---
log "Computing SHA256..."
SHA256=$(sha256sum "${EXE_FILE}" | awk '{print $1}')
printf '%s  %s\n' "${SHA256}" "$(basename "${EXE_FILE}")" > "${UPSTREAM_DIR}/SHA256SUMS"
log "SHA256: ${SHA256}"

# --- metadata ---
METADATA_FILE="${UPSTREAM_DIR}/upstream.json"
cat > "${METADATA_FILE}" <<EOF
{
  "version": "${VERSION}",
  "arch": "${ARCH}",
  "source_url": "${FINAL_URL}",
  "redirect_url": "${UPSTREAM_URL}",
  "filename": "$(basename "${EXE_FILE}")",
  "sha256": "${SHA256}",
  "downloaded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
log "Metadata written: ${METADATA_FILE}"
log "Done. Version=${VERSION}"

# Print version for consumption by callers
info "${VERSION}"
