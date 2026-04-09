#!/usr/bin/env bash
# extract-windows.sh — Extract app.asar from the Windows installer and detect versions
#
# Detects both the Claude app version (from package.json) and the Electron version
# (from the 'version' file). These are the authoritative sources — not the download URL.
#
# NOTE: This script does NOT produce a Linux-runnable Electron binary.
# The Linux Electron runtime is downloaded separately in patch-linux-runtime.sh.
#
# Inputs:  work/upstream/claude-setup.exe (from download-upstream.sh)
# Outputs: work/extracted/    (raw 7z extract)
#          work/app/          (unpacked asar tree)
#          work/extract.json  (app version, electron version, paths)
# Stdout:  the Claude app version string (e.g. "0.10.14") — used by callers
#
# Usage: ./extract-windows.sh
# Env:   WORK_DIR

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
UPSTREAM_DIR="${WORK_DIR}/upstream"
EXTRACT_DIR="${WORK_DIR}/extracted"
APP_DIR="${WORK_DIR}/app"
MSIX_FILE="${UPSTREAM_DIR}/claude.msix"
MSIX_URL="https://claude.ai/api/desktop/win32/x64/msix/latest/redirect"

log() { printf '[extract-windows] %s\n' "$*" >&2; }
die() { printf '[extract-windows] ERROR: %s\n' "$*" >&2; exit 1; }

fct_update_upstream_json_with_msix() {
    local upstream_json="$1"
    local msix_effective_url="$2"
    local msix_redirect_url="$3"
    local msix_sha256="$4"

    [[ -f "${upstream_json}" ]] || return 0

    python3 - "${upstream_json}" "${msix_effective_url}" "${msix_redirect_url}" "${msix_sha256}" <<'PYEOF'
import json
import sys

path, effective_url, redirect_url, sha256 = sys.argv[1:]
with open(path) as f:
    data = json.load(f)

data["payload_source_url"] = effective_url
data["payload_redirect_url"] = redirect_url
data["payload_filename"] = "claude.msix"
data["payload_sha256"] = sha256

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
}

fct_download_bootstrapper_payload_if_needed() {
    local upstream_json="${UPSTREAM_DIR}/upstream.json"
    local msix_effective_url=""
    local msix_sha256=""

    command -v curl >/dev/null 2>&1 || die "curl is required to fetch the bootstrapper MSIX payload"

    if [[ -f "${MSIX_FILE}" ]]; then
        log "Using cached MSIX payload: ${MSIX_FILE}"
    else
        log "Installer appears to be a bootstrapper. Downloading MSIX payload..."
        log "MSIX URL: ${MSIX_URL}"
        curl -L --fail --progress-bar "${MSIX_URL}" -o "${MSIX_FILE}.tmp" || \
            die "Failed to download MSIX payload from ${MSIX_URL}"
        mv "${MSIX_FILE}.tmp" "${MSIX_FILE}"
    fi

    msix_effective_url=$(curl -sL --max-redirs 10 -o /dev/null -w '%{url_effective}' \
        "${MSIX_URL}" 2>/dev/null || echo "${MSIX_URL}")
    msix_sha256=$(sha256sum "${MSIX_FILE}" | awk '{print $1}')
    log "MSIX SHA256: ${msix_sha256}"

    fct_update_upstream_json_with_msix "${upstream_json}" "${msix_effective_url}" "${MSIX_URL}" "${msix_sha256}"

    log "Extracting MSIX payload with 7z..."
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"
    7z x -y "${MSIX_FILE}" -o"${EXTRACT_DIR}" > /dev/null 2>&1 || \
        die "Failed to extract MSIX payload: ${MSIX_FILE}"
}

# --- find the installer ---
# Version is NOT known at this stage — it is detected from the installer content below.
# download-upstream.sh saves as 'claude-setup.exe'; find that or any .exe in upstream dir.
EXE_FILE=$(find "${UPSTREAM_DIR}" -maxdepth 1 -name "*.exe" ! -name "*.tmp*" -type f \
    2>/dev/null | head -1 || true)
[[ -z "${EXE_FILE}" || ! -f "${EXE_FILE}" ]] && \
    die "No installer found in ${UPSTREAM_DIR}. Run download-upstream.sh first."
log "Installer: ${EXE_FILE}"

# --- tool checks ---
command -v 7z >/dev/null 2>&1 || die "p7zip is required (sudo dnf install p7zip p7zip-plugins)"
command -v node >/dev/null 2>&1 || die "node is required"
command -v npm >/dev/null 2>&1 || die "npm is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# --- verify checksum ---
if [[ -f "${UPSTREAM_DIR}/SHA256SUMS" ]]; then
    log "Verifying checksum..."
    (cd "${UPSTREAM_DIR}" && sha256sum -c SHA256SUMS --quiet) || die "Checksum mismatch! File may be corrupted."
    log "Checksum OK."
else
    log "WARNING: No SHA256SUMS file found, skipping checksum verification"
fi

# --- extract installer ---
log "Extracting installer with 7z..."
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
7z x -y "${EXE_FILE}" -o"${EXTRACT_DIR}" > /dev/null 2>&1 || true

log "Raw extraction complete. Locating app resources..."

# Find app.asar — it could be at various depths depending on installer type
ASAR_FILE=$(find "${EXTRACT_DIR}" -name "app.asar" -type f 2>/dev/null | head -1 || true)

# For Squirrel-based installers, there may be a nested nupkg
if [[ -z "${ASAR_FILE}" ]]; then
    log "app.asar not found at first level, looking for nested archives..."
    NESTED_ARCHIVE=$(find "${EXTRACT_DIR}" -name "*.nupkg" -o -name "*.7z" -o -name "app-64.7z" 2>/dev/null | head -1 || true)
    if [[ -n "${NESTED_ARCHIVE}" ]]; then
        log "Found nested archive: ${NESTED_ARCHIVE}"
        NESTED_DIR="${EXTRACT_DIR}/nested"
        mkdir -p "${NESTED_DIR}"
        7z x -y "${NESTED_ARCHIVE}" -o"${NESTED_DIR}" > /dev/null 2>&1 || true
        ASAR_FILE=$(find "${NESTED_DIR}" -name "app.asar" -type f 2>/dev/null | head -1 || true)
    fi
fi

if [[ -z "${ASAR_FILE}" ]]; then
    fct_download_bootstrapper_payload_if_needed
    ASAR_FILE=$(find "${EXTRACT_DIR}" -name "app.asar" -type f 2>/dev/null | head -1 || true)
fi

[[ -z "${ASAR_FILE}" ]] && die "Could not find app.asar in installer or MSIX payload. Upstream structure may have changed."
log "Found app.asar: ${ASAR_FILE}"

RESOURCES_DIR=$(dirname "${ASAR_FILE}")
APP_ROOT=$(dirname "${RESOURCES_DIR}")
log "App root: ${APP_ROOT}"

UNPACKED_DIR="${ASAR_FILE}.unpacked"
if [[ -d "${UNPACKED_DIR}/node_modules/%40ant" ]] && [[ ! -e "${UNPACKED_DIR}/node_modules/@ant" ]]; then
    log "Normalizing unpacked module path: %40ant -> @ant"
    mv "${UNPACKED_DIR}/node_modules/%40ant" "${UNPACKED_DIR}/node_modules/@ant"
fi

# --- detect Electron version from version file ---
# The 'version' file at the app root contains the Electron version string (e.g. "28.3.3")
ELECTRON_VERSION=""
VERSION_FILE=$(find "${APP_ROOT}" -name "version" -maxdepth 1 -type f 2>/dev/null | head -1 || true)
if [[ -f "${VERSION_FILE}" ]]; then
    ELECTRON_VERSION=$(cat "${VERSION_FILE}")
    log "Electron version (from version file): ${ELECTRON_VERSION}"
fi

# Fallback: try to read from app package.json devDependencies
if [[ -z "${ELECTRON_VERSION}" ]]; then
    PKG_JSON_ROOT=$(find "${APP_ROOT}" -name "package.json" -maxdepth 1 2>/dev/null | head -1 || true)
    if [[ -f "${PKG_JSON_ROOT}" ]]; then
        ELECTRON_VERSION=$(python3 -c "
import json, sys, re
data = json.load(open('${PKG_JSON_ROOT}'))
ev = (data.get('devDependencies', {}).get('electron', '') or
      data.get('dependencies', {}).get('electron', ''))
m = re.search(r'\d+\.\d+\.\d+', ev)
print(m.group(0) if m else '')
" 2>/dev/null || true)
        [[ -n "${ELECTRON_VERSION}" ]] && log "Electron version (from package.json): ${ELECTRON_VERSION}"
    fi
fi

[[ -z "${ELECTRON_VERSION}" ]] && die "Could not detect Electron version from installer. Cannot proceed without it to download the Linux runtime."
log "Confirmed Electron version: ${ELECTRON_VERSION}"

# --- unpack app.asar ---
log "Unpacking app.asar..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"

# Install @electron/asar if not available
if ! npx --yes @electron/asar --version > /dev/null 2>&1; then
    log "Installing @electron/asar..."
    npm install --global @electron/asar 2>/dev/null || \
        (cd /tmp && npm install @electron/asar 2>/dev/null && export PATH="/tmp/node_modules/.bin:${PATH}")
fi

npx --yes @electron/asar extract "${ASAR_FILE}" "${APP_DIR}"
log "app.asar unpacked to: ${APP_DIR}"

EXTRACT_META="${WORK_DIR}/extract.json"

# --- detect authoritative app version from package.json ---
[[ -f "${APP_DIR}/package.json" ]] || die "package.json not found in unpacked app — extraction may be incomplete"

APP_VERSION=$(python3 -c "import json,sys; print(json.load(open('${APP_DIR}/package.json')).get('version',''))" 2>/dev/null || \
              grep -oP '"version":\s*"\K[^"]+' "${APP_DIR}/package.json" | head -1 || true)
[[ -z "${APP_VERSION}" ]] && die "Could not read version from ${APP_DIR}/package.json"
log "App version (authoritative): ${APP_VERSION}"

# --- update extract.json and upstream.json with confirmed version ---
ASAR_SHA256=$(sha256sum "${ASAR_FILE}" | awk '{print $1}')
cat > "${EXTRACT_META}" <<EOF
{
  "version": "${APP_VERSION}",
  "asar_path": "${ASAR_FILE}",
  "asar_sha256": "${ASAR_SHA256}",
  "resources_dir": "${RESOURCES_DIR}",
  "app_dir": "${APP_DIR}",
  "electron_version": "${ELECTRON_VERSION}",
  "extracted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Backfill version into upstream.json so provenance is complete
UPSTREAM_JSON="${UPSTREAM_DIR}/upstream.json"
if [[ -f "${UPSTREAM_JSON}" ]]; then
    python3 - "${UPSTREAM_JSON}" "${APP_VERSION}" <<'PYEOF'
import json, sys
path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data['version'] = version
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF
    log "upstream.json updated with version ${APP_VERSION}"
fi

log "Extraction complete."
# Output clean version for callers (no log prefix)
echo "${APP_VERSION}"
