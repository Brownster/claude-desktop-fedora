#!/usr/bin/env bash
# extract-windows.sh — Extract app.asar from the Windows installer and detect Electron version
#
# NOTE: This script does NOT produce a Linux-runnable Electron binary.
# The Linux Electron runtime is downloaded separately in patch-linux-runtime.sh.
#
# Inputs:  work/upstream/Claude-<version>-x64.exe
# Outputs: work/extracted/  (raw 7z extract, Windows content — not used directly in packaging)
#          work/app/        (unpacked asar tree, cross-platform JS)
#          work/extract.json (metadata including detected Electron version)
#
# Usage: ./extract-windows.sh <version>
# Env:   WORK_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
UPSTREAM_DIR="${WORK_DIR}/upstream"
EXTRACT_DIR="${WORK_DIR}/extracted"
APP_DIR="${WORK_DIR}/app"

log()  { printf '[extract-windows] %s\n' "$*" >&2; }
die()  { printf '[extract-windows] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[extract-windows] %s\n' "$*"; }

# --- args ---
VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    # Try to read from metadata
    META="${UPSTREAM_DIR}/upstream.json"
    [[ -f "${META}" ]] || die "No version argument and no upstream.json found. Run download-upstream.sh first."
    VERSION=$(python3 -c "import json,sys; print(json.load(open('${META}'))['version'])" 2>/dev/null || \
              grep -oP '"version":\s*"\K[^"]+' "${META}" | head -1)
fi
[[ -z "${VERSION}" ]] && die "Could not determine version"
log "Version: ${VERSION}"

EXE_FILE="${UPSTREAM_DIR}/Claude-${VERSION}-x64.exe"
[[ -f "${EXE_FILE}" ]] || die "Installer not found: ${EXE_FILE}. Run download-upstream.sh first."

# --- tool checks ---
command -v 7z  >/dev/null 2>&1 || die "p7zip is required (sudo dnf install p7zip p7zip-plugins)"
command -v node >/dev/null 2>&1 || die "node is required"
command -v npm  >/dev/null 2>&1 || die "npm is required"

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

[[ -z "${ASAR_FILE}" ]] && die "Could not find app.asar in installer. Upstream structure may have changed."
log "Found app.asar: ${ASAR_FILE}"

RESOURCES_DIR=$(dirname "${ASAR_FILE}")
APP_ROOT=$(dirname "${RESOURCES_DIR}")
log "App root: ${APP_ROOT}"

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

# --- record extraction metadata ---
EXTRACT_META="${WORK_DIR}/extract.json"
ASAR_SHA256=$(sha256sum "${ASAR_FILE}" | awk '{print $1}')

cat > "${EXTRACT_META}" <<EOF
{
  "version": "${VERSION}",
  "asar_path": "${ASAR_FILE}",
  "asar_sha256": "${ASAR_SHA256}",
  "resources_dir": "${RESOURCES_DIR}",
  "app_dir": "${APP_DIR}",
  "electron_version": "${ELECTRON_VERSION}",
  "extracted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
log "Extraction metadata: ${EXTRACT_META}"

# --- sanity checks ---
[[ -f "${APP_DIR}/package.json" ]] || die "package.json not found in unpacked app — extraction may be incomplete"

APP_VERSION=$(python3 -c "import json,sys; print(json.load(open('${APP_DIR}/package.json')).get('version','unknown'))" 2>/dev/null || \
              grep -oP '"version":\s*"\K[^"]+' "${APP_DIR}/package.json" | head -1 || echo "unknown")
log "App version from package.json: ${APP_VERSION}"

log "Extraction complete."
info "${VERSION}"
