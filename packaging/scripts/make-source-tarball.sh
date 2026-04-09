#!/usr/bin/env bash
# make-source-tarball.sh — Assemble a deterministic source tarball for rpmbuild
#
# The tarball layout (matches what claude-desktop.spec expects):
#   claude-desktop-<version>/
#     claude               — Linux Electron binary (renamed from 'electron')
#     chrome-sandbox       — setuid sandbox helper
#     lib*.so, *.bin, ...  — Electron shared libs and data files
#     resources/
#       app.asar           — repacked patched app
#       claude-desktop.sh  — launcher wrapper
#       claude-desktop.desktop
#     icons/               — PNG icons at various sizes
#     LICENSE              — repo license (MIT, for packaging scripts)
#     build-metadata.json  — full upstream provenance
#
# Inputs:  work/app-patched/       (patched asar contents)
#          work/electron-linux/    (Linux Electron runtime from patch-linux-runtime.sh)
# Outputs: work/sources/claude-desktop-<version>.tar.gz
#
# Usage: ./make-source-tarball.sh <version>
# Env:   WORK_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
PATCHED_DIR="${WORK_DIR}/app-patched"
ELECTRON_LINUX_DIR="${WORK_DIR}/electron-linux"
SOURCES_DIR="${WORK_DIR}/sources"
STAGING_DIR="${WORK_DIR}/staging"
FEDORA_PKG_DIR="${REPO_ROOT}/packaging/fedora"
UPSTREAM_JSON="${WORK_DIR}/upstream/upstream.json"

log()  { printf '[make-source-tarball] %s\n' "$*" >&2; }
die()  { printf '[make-source-tarball] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[make-source-tarball] %s\n' "$*"; }

# --- args ---
VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    [[ -f "${UPSTREAM_JSON}" ]] && \
        VERSION=$(grep -oP '"version":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || true)
fi
[[ -z "${VERSION}" ]] && die "Version required as argument or from upstream/upstream.json"
log "Version: ${VERSION}"

TARBALL_NAME="claude-desktop-${VERSION}"
TARBALL_FILE="${SOURCES_DIR}/${TARBALL_NAME}.tar.gz"

# --- pre-flight checks ---
[[ -d "${PATCHED_DIR}" ]] || die "Patched app dir not found: ${PATCHED_DIR}. Run patch-linux-runtime.sh first."
[[ -d "${ELECTRON_LINUX_DIR}" ]] || die "Linux Electron dir not found: ${ELECTRON_LINUX_DIR}. Run patch-linux-runtime.sh first."

ELECTRON_BIN="${ELECTRON_LINUX_DIR}/electron"
[[ -f "${ELECTRON_BIN}" ]] || die "electron binary not found in: ${ELECTRON_LINUX_DIR}"
file "${ELECTRON_BIN}" | grep -q "ELF.*x86-64" || \
    die "electron binary in ${ELECTRON_LINUX_DIR} is not Linux x86-64 ELF — this should not happen"

mkdir -p "${SOURCES_DIR}"

# --- repack app.asar from patched tree ---
log "Repacking app.asar from patched tree..."
ASAR_OUTPUT="${WORK_DIR}/app.asar"
rm -f "${ASAR_OUTPUT}"
npx --yes @electron/asar pack "${PATCHED_DIR}" "${ASAR_OUTPUT}"
log "Repacked: ${ASAR_OUTPUT} ($(du -sh "${ASAR_OUTPUT}" | cut -f1))"

# --- build staging tree ---
log "Staging tarball contents..."
rm -rf "${STAGING_DIR}"
STAGE="${STAGING_DIR}/${TARBALL_NAME}"
mkdir -p "${STAGE}"/{resources,icons}

# Copy Linux Electron runtime as the base (this is what will become /opt/claude-desktop/)
log "Copying Linux Electron runtime..."
cp -r "${ELECTRON_LINUX_DIR}/." "${STAGE}/"

# Rename 'electron' binary to 'claude' (the app name)
if [[ -f "${STAGE}/electron" ]]; then
    mv "${STAGE}/electron" "${STAGE}/claude"
    log "Renamed electron -> claude"
else
    die "electron binary not found in staging dir after copy — something went wrong"
fi

# Place repacked asar into resources/
cp "${ASAR_OUTPUT}" "${STAGE}/resources/app.asar"
log "Placed app.asar"

# Remove Electron's default_app.asar if present (replaced by ours)
rm -f "${STAGE}/resources/default_app.asar"

# Copy packaging resources from repo
[[ -f "${FEDORA_PKG_DIR}/claude-desktop.sh" ]] && \
    cp "${FEDORA_PKG_DIR}/claude-desktop.sh" "${STAGE}/resources/"
[[ -f "${FEDORA_PKG_DIR}/claude-desktop.desktop" ]] && \
    cp "${FEDORA_PKG_DIR}/claude-desktop.desktop" "${STAGE}/resources/"

# Copy icons
if [[ -d "${FEDORA_PKG_DIR}/icons" ]] && [[ -n "$(ls "${FEDORA_PKG_DIR}/icons/" 2>/dev/null)" ]]; then
    cp -r "${FEDORA_PKG_DIR}/icons/." "${STAGE}/icons/"
fi

# Copy LICENSE (for %license in spec)
[[ -f "${REPO_ROOT}/LICENSE" ]] && cp "${REPO_ROOT}/LICENSE" "${STAGE}/LICENSE"

# --- full upstream provenance in build-metadata.json ---
UPSTREAM_SHA256=""
UPSTREAM_URL=""
UPSTREAM_DOWNLOADED=""
if [[ -f "${UPSTREAM_JSON}" ]]; then
    UPSTREAM_SHA256=$(grep -oP '"sha256":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || true)
    UPSTREAM_URL=$(grep -oP '"source_url":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || true)
    UPSTREAM_DOWNLOADED=$(grep -oP '"downloaded_at":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || true)
else
    log "WARNING: upstream.json not found — provenance metadata will be incomplete"
fi

ELECTRON_VERSION=$(grep -oP '"electron_version":\s*"\K[^"]+' "${WORK_DIR}/extract.json" 2>/dev/null | head -1 || echo "unknown")

cat > "${STAGE}/build-metadata.json" <<EOF
{
  "upstream_version": "${VERSION}",
  "upstream_source_url": "${UPSTREAM_URL}",
  "upstream_installer_sha256": "${UPSTREAM_SHA256}",
  "upstream_downloaded_at": "${UPSTREAM_DOWNLOADED}",
  "electron_version": "${ELECTRON_VERSION}",
  "packaged_by": "claude-desktop-fedora",
  "packaged_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "git_commit": "$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
}
EOF
log "build-metadata.json written with full upstream provenance."

# --- create deterministic tarball ---
log "Creating tarball: ${TARBALL_FILE}"
tar \
    --sort=name \
    --mtime="@0" \
    --owner=0 --group=0 --numeric-owner \
    -czf "${TARBALL_FILE}" \
    -C "${STAGING_DIR}" \
    "${TARBALL_NAME}"

TARBALL_SHA256=$(sha256sum "${TARBALL_FILE}" | awk '{print $1}')
printf '%s  %s\n' "${TARBALL_SHA256}" "$(basename "${TARBALL_FILE}")" > "${SOURCES_DIR}/SHA256SUMS"

log "Tarball: ${TARBALL_FILE}"
log "Size:    $(du -sh "${TARBALL_FILE}" | cut -f1)"
log "SHA256:  ${TARBALL_SHA256}"
log "Done."

info "${TARBALL_FILE}"
