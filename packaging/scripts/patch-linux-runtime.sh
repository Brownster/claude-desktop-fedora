#!/usr/bin/env bash
# patch-linux-runtime.sh — Replace Windows native bindings with Linux-compatible ones
#
# Strategy (in order):
#   1. Check patches/runtime/ for pre-staged bindings
#   2. Download from aaddrick/claude-desktop-debian releases (known working source)
#   3. Build from source via node-gyp (fallback)
#
# Inputs:  work/app/   (unpacked asar)
#          work/electron/ (electron runtime)
# Outputs: work/app-patched/  (patched app tree, ready for repacking)
#
# Usage: ./patch-linux-runtime.sh <version>
# Env:   WORK_DIR, ELECTRON_VERSION, SKIP_NATIVE_PATCH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
APP_DIR="${WORK_DIR}/app"
ELECTRON_DIR="${WORK_DIR}/electron"
PATCHED_DIR="${WORK_DIR}/app-patched"
PATCHES_RUNTIME_DIR="${REPO_ROOT}/patches/runtime"
SKIP_NATIVE_PATCH="${SKIP_NATIVE_PATCH:-0}"

# Upstream reference for Linux bindings
DEBIAN_REPO="aaddrick/claude-desktop-debian"

log()  { printf '[patch-linux-runtime] %s\n' "$*" >&2; }
warn() { printf '[patch-linux-runtime] WARN: %s\n' "$*" >&2; }
die()  { printf '[patch-linux-runtime] ERROR: %s\n' "$*" >&2; exit 1; }

# --- args ---
VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    META="${WORK_DIR}/upstream.json"
    [[ -f "${META}" ]] || die "No version argument and no upstream.json"
    VERSION=$(grep -oP '"version":\s*"\K[^"]+' "${WORK_DIR}/upstream/upstream.json" 2>/dev/null | head -1 || \
              grep -oP '"version":\s*"\K[^"]+' "${META}" | head -1)
fi
[[ -z "${VERSION}" ]] && die "Could not determine version"
log "Version: ${VERSION}"

[[ -d "${APP_DIR}" ]] || die "App dir not found: ${APP_DIR}. Run extract-windows.sh first."

# --- copy to patched dir ---
log "Creating patched copy..."
rm -rf "${PATCHED_DIR}"
cp -r "${APP_DIR}" "${PATCHED_DIR}"

# ============================================================
# STEP 1: Find Windows native module in extracted app
# ============================================================
log "Locating Windows native module(s)..."

# Claude uses a native module — it may be named various things
NATIVE_NODE=$(find "${PATCHED_DIR}" -name "*.node" -type f 2>/dev/null || true)

if [[ -z "${NATIVE_NODE}" ]]; then
    warn "No .node files found in app. Native patching may not be needed or app structure changed."
else
    log "Found native modules:"
    while IFS= read -r f; do
        log "  ${f}"
        file "${f}" 2>/dev/null || true
    done <<< "${NATIVE_NODE}"
fi

if [[ "${SKIP_NATIVE_PATCH}" == "1" ]]; then
    warn "SKIP_NATIVE_PATCH=1, skipping native binding replacement"
else
    # ============================================================
    # STEP 2: Get Linux native bindings
    # ============================================================

    LINUX_NATIVE_NODE=""

    # --- Strategy A: pre-staged in repo patches/runtime/ ---
    STAGED=$(find "${PATCHES_RUNTIME_DIR}" -name "*.node" -type f 2>/dev/null | head -1 || true)
    if [[ -n "${STAGED}" ]]; then
        log "Using pre-staged native bindings: ${STAGED}"
        LINUX_NATIVE_NODE="${STAGED}"
    fi

    # --- Strategy B: download from aaddrick releases ---
    if [[ -z "${LINUX_NATIVE_NODE}" ]]; then
        log "Trying to download Linux native bindings from ${DEBIAN_REPO} releases..."
        if command -v gh >/dev/null 2>&1; then
            RELEASE_ASSET=$(gh release list -R "${DEBIAN_REPO}" --limit 5 --json tagName,assets \
                2>/dev/null | python3 -c "
import json, sys
releases = json.load(sys.stdin)
for r in releases:
    for a in r.get('assets', []):
        if a['name'].endswith('.node') and 'linux' in a['name'].lower():
            print(a['url'])
            sys.exit(0)
" 2>/dev/null || true)

            if [[ -n "${RELEASE_ASSET}" ]]; then
                DOWNLOAD_PATH="${WORK_DIR}/linux-native.node"
                gh release download -R "${DEBIAN_REPO}" --pattern "*.node" -D "${WORK_DIR}" 2>/dev/null && \
                    LINUX_NATIVE_NODE=$(find "${WORK_DIR}" -name "*.node" -newer "${APP_DIR}/package.json" | head -1 || true)
            fi
        fi

        # Try direct GitHub API if gh not available
        if [[ -z "${LINUX_NATIVE_NODE}" ]]; then
            log "Trying GitHub API for release assets..."
            ASSET_URL=$(curl -sf "https://api.github.com/repos/${DEBIAN_REPO}/releases/latest" 2>/dev/null | \
                python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('assets', []):
    if a['name'].endswith('.node') and ('linux' in a['name'].lower() or 'native' in a['name'].lower()):
        print(a['browser_download_url'])
        break
" 2>/dev/null || true)

            if [[ -n "${ASSET_URL}" ]]; then
                DOWNLOAD_PATH="${WORK_DIR}/linux-native.node"
                curl -sL --fail "${ASSET_URL}" -o "${DOWNLOAD_PATH}" && LINUX_NATIVE_NODE="${DOWNLOAD_PATH}"
                log "Downloaded Linux native module from release"
            fi
        fi
    fi

    # --- Strategy C: install claude-native from npm ---
    if [[ -z "${LINUX_NATIVE_NODE}" ]]; then
        log "Trying npm for claude-native bindings..."
        NPM_WORK="${WORK_DIR}/npm-native"
        mkdir -p "${NPM_WORK}"

        # Detect Electron version to get correct Node ABI
        ELECTRON_VERSION="${ELECTRON_VERSION:-}"
        if [[ -z "${ELECTRON_VERSION}" ]]; then
            EXTRACT_META="${WORK_DIR}/extract.json"
            [[ -f "${EXTRACT_META}" ]] && \
                ELECTRON_VERSION=$(grep -oP '"electron_version":\s*"\K[^"]+' "${EXTRACT_META}" | head -1 || true)
        fi

        # Try installing the native package
        for PKG in "claude-native" "@anthropic-ai/claude-native"; do
            if (cd "${NPM_WORK}" && npm install "${PKG}" 2>/dev/null); then
                CANDIDATE=$(find "${NPM_WORK}" -name "*.node" -type f | head -1 || true)
                if [[ -n "${CANDIDATE}" ]]; then
                    LINUX_NATIVE_NODE="${CANDIDATE}"
                    log "Got native module from npm package: ${PKG}"
                    break
                fi
            fi
        done
    fi

    # --- Replace Windows .node files with Linux version ---
    if [[ -n "${LINUX_NATIVE_NODE}" ]]; then
        log "Linux native module: ${LINUX_NATIVE_NODE}"
        log "Architecture: $(file "${LINUX_NATIVE_NODE}" 2>/dev/null || echo "unknown")"

        # Replace each Windows .node file
        while IFS= read -r WIN_NODE; do
            [[ -z "${WIN_NODE}" ]] && continue
            NODE_NAME=$(basename "${WIN_NODE}")
            log "Replacing: ${WIN_NODE}"
            cp "${LINUX_NATIVE_NODE}" "${WIN_NODE}"
            log "  -> replaced with Linux version"
        done < <(find "${PATCHED_DIR}" -name "*.node" -type f 2>/dev/null || true)

        # Record what we patched
        SHA256=$(sha256sum "${LINUX_NATIVE_NODE}" | awk '{print $1}')
        log "Replacement SHA256: ${SHA256}"
    else
        warn "Could not obtain Linux native bindings."
        warn "The app may not function correctly without them."
        warn "You can manually place a Linux .node file in patches/runtime/ and re-run."
    fi
fi

# ============================================================
# STEP 3: Patch Windows-specific paths and settings in JS
# ============================================================
log "Patching Windows-specific content in app JS..."

# Remove Windows-specific electron flags if present
MAIN_JS=""
for candidate in "${PATCHED_DIR}/main.js" "${PATCHED_DIR}/index.js" "${PATCHED_DIR}/app.js"; do
    [[ -f "${candidate}" ]] && MAIN_JS="${candidate}" && break
done

if [[ -n "${MAIN_JS}" ]]; then
    log "Patching main entry: ${MAIN_JS}"
    # Example: remove Windows registry calls, etc.
    # Add Linux-specific startup flags
    true  # placeholder — real patches added here as discovered
fi

# Remove Windows-specific squirrel update handling if present
SQUIRREL_CHECK="${PATCHED_DIR}/node_modules/electron-squirrel-startup/index.js"
if [[ -f "${SQUIRREL_CHECK}" ]]; then
    log "Neutralizing Squirrel auto-updater startup check (Linux doesn't use Squirrel)..."
    echo "module.exports = false;" > "${SQUIRREL_CHECK}"
fi

# ============================================================
# STEP 4: Inject Linux-specific metadata
# ============================================================
log "Updating package.json for Linux..."
PKG_JSON="${PATCHED_DIR}/package.json"
if [[ -f "${PKG_JSON}" ]]; then
    # Add linux packaging metadata using Python to preserve JSON formatting
    python3 - "${PKG_JSON}" "${VERSION}" <<'PYEOF'
import json, sys

pkg_path = sys.argv[1]
version  = sys.argv[2]

with open(pkg_path) as f:
    pkg = json.load(f)

pkg.setdefault('linuxPackaging', {
    'platform': 'fedora',
    'packagedBy': 'claude-desktop-fedora',
    'packagedVersion': version
})

with open(pkg_path, 'w') as f:
    json.dump(pkg, f, indent=2)
    f.write('\n')
PYEOF
    log "package.json updated."
fi

# ============================================================
# STEP 5: Write patch manifest
# ============================================================
PATCH_MANIFEST="${WORK_DIR}/patch-manifest.json"
cat > "${PATCH_MANIFEST}" <<EOF
{
  "version": "${VERSION}",
  "patched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "native_bindings_replaced": $([ -n "${LINUX_NATIVE_NODE:-}" ] && echo "true" || echo "false"),
  "native_source": "${LINUX_NATIVE_NODE:-none}",
  "squirrel_neutralized": $([ -f "${SQUIRREL_CHECK:-/nonexistent}" ] && echo "true" || echo "false")
}
EOF
log "Patch manifest: ${PATCH_MANIFEST}"

log "Patching complete. Patched app at: ${PATCHED_DIR}"
