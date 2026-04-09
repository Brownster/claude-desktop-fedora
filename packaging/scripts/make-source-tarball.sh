#!/usr/bin/env bash
# make-source-tarball.sh — Assemble a deterministic source tarball for rpmbuild
#
# The tarball layout matches what claude-desktop.spec expects:
#   claude-desktop-<version>/
#     app/          — patched asar contents
#     electron/     — electron runtime (linux binaries)
#     resources/    — icons, .desktop, launcher script (copied from packaging/fedora/)
#
# Inputs:  work/app-patched/, work/electron/
# Outputs: work/sources/claude-desktop-<version>.tar.gz
#
# Usage: ./make-source-tarball.sh <version>
# Env:   WORK_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
PATCHED_DIR="${WORK_DIR}/app-patched"
ELECTRON_DIR="${WORK_DIR}/electron"
SOURCES_DIR="${WORK_DIR}/sources"
STAGING_DIR="${WORK_DIR}/staging"
FEDORA_PKG_DIR="${REPO_ROOT}/packaging/fedora"

log()  { printf '[make-source-tarball] %s\n' "$*" >&2; }
die()  { printf '[make-source-tarball] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[make-source-tarball] %s\n' "$*"; }

# --- args ---
VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    UPSTREAM_JSON="${WORK_DIR}/upstream/upstream.json"
    [[ -f "${UPSTREAM_JSON}" ]] && \
        VERSION=$(grep -oP '"version":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || true)
fi
[[ -z "${VERSION}" ]] && die "Version required as argument or from upstream.json"
log "Version: ${VERSION}"

TARBALL_NAME="claude-desktop-${VERSION}"
TARBALL_FILE="${SOURCES_DIR}/${TARBALL_NAME}.tar.gz"

[[ -d "${PATCHED_DIR}" ]] || die "Patched app dir not found: ${PATCHED_DIR}. Run patch-linux-runtime.sh first."

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
mkdir -p "${STAGING_DIR}/${TARBALL_NAME}"/{resources,icons}

# Copy Electron runtime (Linux binaries)
if [[ -d "${ELECTRON_DIR}" ]]; then
    log "Copying Electron runtime..."
    cp -r "${ELECTRON_DIR}/." "${STAGING_DIR}/${TARBALL_NAME}/"
else
    log "WARNING: No electron dir found, tarball will only contain app files"
    mkdir -p "${STAGING_DIR}/${TARBALL_NAME}"
fi

# Place repacked asar
mkdir -p "${STAGING_DIR}/${TARBALL_NAME}/resources"
cp "${ASAR_OUTPUT}" "${STAGING_DIR}/${TARBALL_NAME}/resources/app.asar"

# Copy packaging resources
if [[ -d "${FEDORA_PKG_DIR}/icons" ]]; then
    cp -r "${FEDORA_PKG_DIR}/icons/." "${STAGING_DIR}/${TARBALL_NAME}/icons/"
fi

if [[ -f "${FEDORA_PKG_DIR}/claude-desktop.desktop" ]]; then
    cp "${FEDORA_PKG_DIR}/claude-desktop.desktop" "${STAGING_DIR}/${TARBALL_NAME}/resources/"
fi

if [[ -f "${FEDORA_PKG_DIR}/claude-desktop.sh" ]]; then
    cp "${FEDORA_PKG_DIR}/claude-desktop.sh" "${STAGING_DIR}/${TARBALL_NAME}/resources/"
fi

# Write build metadata into the tarball
cat > "${STAGING_DIR}/${TARBALL_NAME}/build-metadata.json" <<EOF
{
  "upstream_version": "${VERSION}",
  "packaged_by": "claude-desktop-fedora",
  "tarball_created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "git_commit": "$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
}
EOF

# --- create tarball deterministically ---
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
