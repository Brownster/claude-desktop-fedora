#!/usr/bin/env bash
# generate-release-notes.sh — Generate GitHub release notes with build metadata
#
# Outputs release notes to stdout (suitable for gh release create --notes)
#
# Usage: ./generate-release-notes.sh <version> [rpm_release]
# Env:   WORK_DIR, DIST_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"

VERSION="${1:-}"
RPM_RELEASE="${2:-1}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -z "${VERSION}" ]] && die "Usage: $0 <version> [rpm_release]"

# Read upstream metadata
UPSTREAM_JSON="${WORK_DIR}/upstream/upstream.json"
UPSTREAM_SHA256=""
UPSTREAM_URL=""
DOWNLOAD_DATE=""

if [[ -f "${UPSTREAM_JSON}" ]]; then
    UPSTREAM_SHA256=$(grep -oP '"sha256":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || echo "unavailable")
    UPSTREAM_URL=$(grep -oP '"source_url":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || echo "unavailable")
    DOWNLOAD_DATE=$(grep -oP '"downloaded_at":\s*"\K[^"]+' "${UPSTREAM_JSON}" | head -1 || echo "unavailable")
fi

# Compute RPM checksums
RPM_FILE=$(find "${DIST_DIR}" -name "claude-desktop-${VERSION}-${RPM_RELEASE}.*.rpm" ! -name "*.src.rpm" 2>/dev/null | head -1 || true)
RPM_SHA256=""
RPM_SIZE=""
if [[ -f "${RPM_FILE}" ]]; then
    RPM_SHA256=$(sha256sum "${RPM_FILE}" | awk '{print $1}')
    RPM_SIZE=$(du -sh "${RPM_FILE}" | cut -f1)
fi

# Git metadata
GIT_COMMIT=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_SHORT=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
FEDORA_VERSION=$(rpm --eval '%{fedora}' 2>/dev/null || echo "unknown")

cat <<EOF
## Claude Desktop ${VERSION} for Fedora

Unofficial Fedora RPM repackage of the official [Claude Desktop](https://claude.ai/download) Windows release.

> **Note**: This is not an official Anthropic release. See [threat model](docs/threat-model.md) for trust information.

### Installation

**Quick install (RPM):**
\`\`\`bash
sudo dnf install ./claude-desktop-${VERSION}-${RPM_RELEASE}.x86_64.rpm
\`\`\`

**Or via DNF repo** (if configured):
\`\`\`bash
sudo dnf install claude-desktop
\`\`\`

**Verify before installing:**
\`\`\`bash
sha256sum -c claude-desktop-${VERSION}-${RPM_RELEASE}.x86_64.rpm.sha256
\`\`\`

### What's inside

| Item | Value |
|------|-------|
| Upstream Claude version | \`${VERSION}\` |
| RPM release | \`${RPM_RELEASE}\` |
| RPM size | ${RPM_SIZE:-N/A} |
| Built for | Fedora ${FEDORA_VERSION} x86_64 |

### Verification

**RPM SHA256:**
\`\`\`
${RPM_SHA256:-N/A}  claude-desktop-${VERSION}-${RPM_RELEASE}.x86_64.rpm
\`\`\`

**Upstream Windows installer SHA256:**
\`\`\`
${UPSTREAM_SHA256:-N/A}
\`\`\`

**Build metadata:**
- Packaging repo commit: [\`${GIT_COMMIT_SHORT}\`](../../commit/${GIT_COMMIT})
- Upstream source: ${UPSTREAM_URL:-N/A}
- Upstream downloaded: ${DOWNLOAD_DATE:-N/A}

### Known issues & notes
- Wayland support: enabled via \`--ozone-platform-hint=auto\` in the launcher
- MCP config: \`~/.config/Claude/claude_desktop_config.json\`
- If the app fails to start, check \`journalctl --user -xe\` or run \`claude-desktop\` from terminal

### Acknowledgements
Build pipeline based on the approach pioneered by [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian).
EOF
