#!/usr/bin/env bash
# publish-release.sh — Publish locally built RPM artifacts to a GitHub release
#
# Usage: ./publish-release.sh <tag> [rpm_release]
# Example:
#   ./packaging/scripts/publish-release.sh v1.2.3-packaging.1 1
#
# Requires:
#   - dist/ contains the built RPM(s)
#   - gh is authenticated for the target repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"

TAG="${1:-}"
RPM_RELEASE="${2:-1}"

die() { printf '[publish-release] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[publish-release] %s\n' "$*" >&2; }

[[ -n "${TAG}" ]] || die "Usage: $0 <tag> [rpm_release]"
command -v gh >/dev/null 2>&1 || die "gh CLI is required"

UPSTREAM_VERSION=$(echo "${TAG}" | sed 's/^v//' | sed 's/-packaging\.[0-9]*$//')
[[ -n "${UPSTREAM_VERSION}" ]] || die "Could not parse upstream version from tag: ${TAG}"

RPM_FILE=$(find "${DIST_DIR}" -maxdepth 1 -name "claude-desktop-${UPSTREAM_VERSION}-${RPM_RELEASE}*.rpm" ! -name "*.src.rpm" | head -1 || true)
[[ -f "${RPM_FILE}" ]] || die "Built RPM not found in ${DIST_DIR} for version ${UPSTREAM_VERSION} release ${RPM_RELEASE}"

log "Generating release notes..."
"${SCRIPT_DIR}/generate-release-notes.sh" "${UPSTREAM_VERSION}" "${RPM_RELEASE}" > /tmp/release-notes.md

log "Generating checksums..."
(
    cd "${DIST_DIR}"
    sha256sum *.rpm > SHA256SUMS
    for f in *.rpm; do
        sha256sum "${f}" > "${f}.sha256"
    done
)

log "Creating GitHub release ${TAG}..."
(
    cd "${DIST_DIR}"
    gh release create "${TAG}" \
        --title "Claude Desktop ${UPSTREAM_VERSION} (Fedora)" \
        --notes-file /tmp/release-notes.md \
        --verify-tag \
        claude-desktop-*.rpm \
        claude-desktop-*.rpm.sha256 \
        SHA256SUMS
)

log "Release published."
