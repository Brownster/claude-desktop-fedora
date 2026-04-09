#!/usr/bin/env bash
# build-rpm.sh — Orchestrate the full build pipeline and produce an RPM
#
# Runs: download → extract → patch → tarball → rpmbuild
# Outputs: dist/claude-desktop-<version>-1.x86_64.rpm
#
# Usage: ./build-rpm.sh [--skip-download] [--skip-extract] [--release N]
# Env:   WORK_DIR, RPM_RELEASE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
DIST_DIR="${REPO_ROOT}/dist"
FEDORA_PKG_DIR="${REPO_ROOT}/packaging/fedora"
SPEC_FILE="${FEDORA_PKG_DIR}/claude-desktop.spec"
RPM_RELEASE="${RPM_RELEASE:-1}"

SKIP_DOWNLOAD=0
SKIP_EXTRACT=0

log()  { printf '\n[build-rpm] === %s ===\n' "$*" >&2; }
die()  { printf '[build-rpm] ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '[build-rpm] %s\n' "$*" >&2; }

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)       RPM_RELEASE="$2"; shift 2 ;;
        --skip-download) SKIP_DOWNLOAD=1; shift ;;
        --skip-extract)  SKIP_EXTRACT=1; shift ;;
        --help|-h)
            cat <<EOF
Usage: build-rpm.sh [OPTIONS]

Options:
  --release N        RPM release number (default: 1)
  --skip-download    Skip downloading upstream installer
  --skip-extract     Skip extracting the installer
  -h, --help         Show this help

Environment:
  WORK_DIR           Working directory (default: <repo>/work)
  RPM_RELEASE        RPM release number (default: 1)
EOF
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# --- prerequisite check ---
log "Checking prerequisites"
MISSING=()
for cmd in 7z node npm rpmbuild sha256sum curl tar python3; do
    command -v "${cmd}" >/dev/null 2>&1 || MISSING+=("${cmd}")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Missing tools: ${MISSING[*]}
Install with: sudo dnf install -y git curl jq unzip p7zip p7zip-plugins rpm-build rpmdevtools desktop-file-utils file which tar xz nodejs npm bubblewrap"
fi

step "All prerequisites met."
mkdir -p "${WORK_DIR}" "${DIST_DIR}"

# --- step 1: download ---
log "Step 1: Download upstream installer"
if [[ "${SKIP_DOWNLOAD}" == "1" ]]; then
    step "Skipping download (--skip-download)"
else
    "${SCRIPT_DIR}/download-upstream.sh"
fi

# --- step 2: extract (version detected here, not from download) ---
log "Step 2: Extract Windows installer"
if [[ "${SKIP_EXTRACT}" == "1" ]]; then
    step "Skipping extraction (--skip-extract)"
    # Read version from extract.json written by a previous run
    EXTRACT_JSON="${WORK_DIR}/extract.json"
    [[ -f "${EXTRACT_JSON}" ]] || die "No extract.json found. Cannot skip extract without a prior run."
    VERSION=$(grep -oP '"version":\s*"\K[^"]+' "${EXTRACT_JSON}" | head -1)
else
    VERSION=$("${SCRIPT_DIR}/extract-windows.sh" | tail -1)
fi
[[ -z "${VERSION}" || "${VERSION}" == "pending" ]] && die "Could not determine app version from installer"
step "Version: ${VERSION}"

# --- step 3: patch ---
log "Step 3: Patch Linux runtime"
"${SCRIPT_DIR}/patch-linux-runtime.sh" "${VERSION}"

# --- step 4: tarball ---
log "Step 4: Create source tarball"
TARBALL=$("${SCRIPT_DIR}/make-source-tarball.sh" "${VERSION}" | tail -1)
[[ -f "${TARBALL}" ]] || die "Tarball not created: ${TARBALL}"
step "Tarball: ${TARBALL}"

# --- step 5: rpmbuild setup ---
log "Step 5: Configure rpmbuild environment"
RPMBUILD_ROOT="${WORK_DIR}/rpmbuild"
mkdir -p "${RPMBUILD_ROOT}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# Place source tarball
cp "${TARBALL}" "${RPMBUILD_ROOT}/SOURCES/"
# Copy spec file
cp "${SPEC_FILE}" "${RPMBUILD_ROOT}/SPECS/"

step "rpmbuild tree ready at: ${RPMBUILD_ROOT}"

# --- step 6: rpmbuild ---
log "Step 6: Build RPM"
rpmbuild \
    -ba \
    --define "_topdir ${RPMBUILD_ROOT}" \
    --define "upstream_version ${VERSION}" \
    --define "rpm_release ${RPM_RELEASE}" \
    "${RPMBUILD_ROOT}/SPECS/claude-desktop.spec"

# --- collect output ---
log "Step 7: Collect artifacts"
find "${RPMBUILD_ROOT}/RPMS" -name "*.rpm" | while read -r rpm; do
    cp "${rpm}" "${DIST_DIR}/"
    step "Built: ${DIST_DIR}/$(basename "${rpm}")"
done

find "${RPMBUILD_ROOT}/SRPMS" -name "*.rpm" | while read -r srpm; do
    cp "${srpm}" "${DIST_DIR}/"
    step "SRPM: ${DIST_DIR}/$(basename "${srpm}")"
done

# --- verify ---
log "Step 8: Verify RPM"
"${SCRIPT_DIR}/verify-artifact.sh" "${DIST_DIR}/claude-desktop-${VERSION}-${RPM_RELEASE}.x86_64.rpm" 2>/dev/null || \
    "${SCRIPT_DIR}/verify-artifact.sh" "$(find "${DIST_DIR}" -name "claude-desktop-*.x86_64.rpm" | head -1)"

log "Build complete"
step "Artifacts in: ${DIST_DIR}/"
ls -lh "${DIST_DIR}"/*.rpm 2>/dev/null || true
