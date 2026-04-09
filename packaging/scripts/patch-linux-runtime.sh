#!/usr/bin/env bash
# patch-linux-runtime.sh — Download Linux Electron runtime and replace Windows native modules
#
# This script does two distinct jobs:
#
#   1. Download the official Linux Electron release matching the version bundled in
#      the Windows installer. This produces work/electron-linux/ which IS the Linux
#      runtime that ends up in the RPM.
#
#   2. Replace any Windows-only .node (native module) files in the unpacked app with
#      Linux ELF equivalents. The pipeline FAILS if a module is found but no Linux
#      replacement can be obtained — it does not silently continue with broken binaries.
#
# Native module replacement sources (tried in order per module):
#   A. patches/runtime/<module-name>.node (pre-staged in repo — most reliable)
#   B. aaddrick/claude-desktop-debian GitHub releases (matching by filename)
#   C. npm install (last resort)
#
# Inputs:  work/app/        (unpacked asar from extract-windows.sh)
#          work/extract.json (must contain electron_version)
# Outputs: work/electron-linux/   (Linux Electron runtime — becomes /opt/claude-desktop/)
#          work/app-patched/      (app tree with Linux .node files)
#          work/patch-manifest.json
#
# Usage: ./patch-linux-runtime.sh [version]
# Env:   WORK_DIR, ELECTRON_VERSION (override), SKIP_NATIVE_PATCH=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
APP_DIR="${WORK_DIR}/app"
PATCHED_DIR="${WORK_DIR}/app-patched"
ELECTRON_LINUX_DIR="${WORK_DIR}/electron-linux"
PATCHES_RUNTIME_DIR="${REPO_ROOT}/patches/runtime"
SKIP_NATIVE_PATCH="${SKIP_NATIVE_PATCH:-0}"
DEBIAN_REPO="aaddrick/claude-desktop-debian"

log()  { printf '[patch-linux-runtime] %s\n' "$*" >&2; }
die()  { printf '[patch-linux-runtime] ERROR: %s\n' "$*" >&2; exit 1; }

# ============================================================
# Resolve version and Electron version
# ============================================================
VERSION="${1:-}"
EXTRACT_META="${WORK_DIR}/extract.json"

if [[ -z "${VERSION}" ]]; then
    [[ -f "${EXTRACT_META}" ]] || die "No version argument and no extract.json. Run extract-windows.sh first."
    VERSION=$(grep -oP '"version":\s*"\K[^"]+' "${EXTRACT_META}" | head -1 || true)
fi
[[ -z "${VERSION}" ]] && die "Could not determine app version"
log "App version: ${VERSION}"

ELECTRON_VERSION="${ELECTRON_VERSION:-}"
if [[ -z "${ELECTRON_VERSION}" ]]; then
    [[ -f "${EXTRACT_META}" ]] || die "extract.json not found — run extract-windows.sh first"
    ELECTRON_VERSION=$(grep -oP '"electron_version":\s*"\K[^"]+' "${EXTRACT_META}" | head -1 || true)
fi
[[ -z "${ELECTRON_VERSION}" ]] && die "Electron version not found in extract.json — cannot download Linux runtime"
log "Electron version: ${ELECTRON_VERSION}"

[[ -d "${APP_DIR}" ]] || die "App dir not found: ${APP_DIR}. Run extract-windows.sh first."

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v unzip >/dev/null 2>&1 || die "unzip is required"
command -v file >/dev/null 2>&1 || die "file (from file-libs) is required"
command -v make >/dev/null 2>&1 || die "make is required to rebuild native modules"
command -v g++ >/dev/null 2>&1 || die "g++ (from gcc-c++) is required to rebuild native modules"

# ============================================================
# STEP 1: Download Linux Electron runtime
# ============================================================
log "=== Step 1: Linux Electron runtime ==="

ELECTRON_ZIP="${WORK_DIR}/electron-${ELECTRON_VERSION}-linux-x64.zip"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip"

if [[ -d "${ELECTRON_LINUX_DIR}" ]] && [[ -x "${ELECTRON_LINUX_DIR}/electron" ]]; then
    log "Linux Electron already present: ${ELECTRON_LINUX_DIR}"
else
    rm -rf "${ELECTRON_LINUX_DIR}"
    mkdir -p "${ELECTRON_LINUX_DIR}"

    if [[ ! -f "${ELECTRON_ZIP}" ]]; then
        log "Downloading Linux Electron v${ELECTRON_VERSION}..."
        log "URL: ${ELECTRON_URL}"
        curl -L --fail --progress-bar "${ELECTRON_URL}" -o "${ELECTRON_ZIP}.tmp" || \
            die "Failed to download Linux Electron v${ELECTRON_VERSION}.
URL tried: ${ELECTRON_URL}
Check that this Electron version exists at https://github.com/electron/electron/releases"
        mv "${ELECTRON_ZIP}.tmp" "${ELECTRON_ZIP}"
    else
        log "Using cached Electron zip: ${ELECTRON_ZIP}"
    fi

    log "Extracting Linux Electron..."
    unzip -q "${ELECTRON_ZIP}" -d "${ELECTRON_LINUX_DIR}" || \
        die "Failed to extract Electron zip: ${ELECTRON_ZIP}"

    # Validate the binary is actually Linux ELF x86-64
    ELECTRON_BIN="${ELECTRON_LINUX_DIR}/electron"
    [[ -f "${ELECTRON_BIN}" ]] || \
        die "electron binary not found after extraction — zip may be corrupt or structure changed"

    FILE_OUT=$(file "${ELECTRON_BIN}")
    echo "${FILE_OUT}" | grep -q "ELF.*x86-64" || \
        die "Downloaded electron binary is not Linux x86-64 ELF.
Got: ${FILE_OUT}
This should not happen with a legitimate electron release."

    chmod 755 "${ELECTRON_BIN}"
    log "Linux Electron v${ELECTRON_VERSION} ready: ${ELECTRON_LINUX_DIR}"
    log "Binary: ${FILE_OUT}"
fi

# Confirm chrome-sandbox setuid helper is present
[[ -f "${ELECTRON_LINUX_DIR}/chrome-sandbox" ]] || \
    log "WARNING: chrome-sandbox not found in Electron package — sandbox will be unavailable"

# ============================================================
# STEP 2: Patch native modules
# ============================================================
log "=== Step 2: Patch native modules ==="

log "Creating patched copy of app..."
rm -rf "${PATCHED_DIR}"
cp -r "${APP_DIR}" "${PATCHED_DIR}"

# Drop Windows-only native baggage before scanning for Linux replacements.
# `node-pty` only needs pty.node on Linux, and Claude's JS wrapper tolerates
# `@ant/claude-native` being unavailable by catching the require() failure.
for remove_path in \
    "${PATCHED_DIR}/node_modules/node-pty/build/Release/conpty.node" \
    "${PATCHED_DIR}/node_modules/node-pty/build/Release/conpty_console_list.node" \
    "${PATCHED_DIR}/node_modules/node-pty/build/Release/winpty-agent.exe" \
    "${PATCHED_DIR}/node_modules/node-pty/build/Release/winpty.dll" \
    "${PATCHED_DIR}/node_modules/@ant/claude-native/claude-native-binding.node"; do
    if [[ -e "${remove_path}" ]]; then
        rm -f "${remove_path}"
        log "Removed Windows-only/optional artifact: ${remove_path#${PATCHED_DIR}/}"
    fi
done

# Catalog all Windows .node files in the unpacked app
declare -A WIN_NODES  # module_basename -> full_path_in_patched_dir
while IFS= read -r node_path; do
    [[ -z "${node_path}" ]] && continue
    mod_name=$(basename "${node_path}")
    WIN_NODES["${mod_name}"]="${node_path}"
done < <(find "${PATCHED_DIR}" -name "*.node" -type f 2>/dev/null || true)

if [[ ${#WIN_NODES[@]} -eq 0 ]]; then
    log "No .node files found in app — no native module replacement needed."
elif [[ "${SKIP_NATIVE_PATCH}" == "1" ]]; then
    log "WARNING: SKIP_NATIVE_PATCH=1 — skipping native module replacement."
    log "         The .node files currently in the patched dir are Windows PE32+ and WILL NOT RUN on Linux."
else
    log "Found ${#WIN_NODES[@]} native module(s) to replace:"
    for mod_name in "${!WIN_NODES[@]}"; do
        log "  ${mod_name} <- $(file "${WIN_NODES[${mod_name}]}" | sed 's/.*: //')"
    done

    REPLACE_FAILED=0

    for mod_name in "${!WIN_NODES[@]}"; do
        win_path="${WIN_NODES[${mod_name}]}"
        log "--- Replacing: ${mod_name} ---"

        LINUX_NODE=""

        # Strategy A: pre-staged in patches/runtime/<exact-name>
        if [[ -f "${PATCHES_RUNTIME_DIR}/${mod_name}" ]]; then
            LINUX_NODE="${PATCHES_RUNTIME_DIR}/${mod_name}"
            log "  Source: pre-staged (${LINUX_NODE})"
        fi

        # Strategy B: download from aaddrick/claude-desktop-debian releases
        if [[ -z "${LINUX_NODE}" ]]; then
            log "  Trying aaddrick releases for: ${mod_name}"
            ASSET_URL=$(curl -sf \
                "https://api.github.com/repos/${DEBIAN_REPO}/releases/latest" \
                -H "Accept: application/vnd.github.v3+json" 2>/dev/null | \
            python3 -c "
import json, sys
data = json.load(sys.stdin)
target = sys.argv[1]
# Exact filename match only — do not fall back to 'any .node file'
# because copying the wrong module silently produces a broken build
for a in data.get('assets', []):
    name = a['name']
    if name == target or name.endswith('_' + target) or name.endswith('-' + target):
        print(a['browser_download_url'])
        sys.exit(0)
" "${mod_name}" 2>/dev/null || true)

            if [[ -n "${ASSET_URL}" ]]; then
                DOWNLOAD_PATH="${WORK_DIR}/${mod_name}"
                curl -sL --fail "${ASSET_URL}" -o "${DOWNLOAD_PATH}" && LINUX_NODE="${DOWNLOAD_PATH}"
                log "  Source: aaddrick release (${ASSET_URL})"
            fi
        fi

        # Strategy C: npm
        if [[ -z "${LINUX_NODE}" ]]; then
            log "  Trying npm for native module..."
            NPM_WORK="${WORK_DIR}/npm-native-$$"
            mkdir -p "${NPM_WORK}"

            PACKAGE_JSON=""
            SEARCH_DIR=$(dirname "${win_path}")
            while [[ "${SEARCH_DIR}" != "${PATCHED_DIR}" && "${SEARCH_DIR}" != "/" ]]; do
                if [[ -f "${SEARCH_DIR}/package.json" ]]; then
                    PACKAGE_JSON="${SEARCH_DIR}/package.json"
                    break
                fi
                SEARCH_DIR=$(dirname "${SEARCH_DIR}")
            done

            PKG_SPEC=""
            if [[ -n "${PACKAGE_JSON}" ]]; then
                PKG_META=$(python3 - "${PACKAGE_JSON}" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

name = data.get("name", "")
version = data.get("version", "")
is_private = "true" if data.get("private") else "false"
print(f"{name}\t{version}\t{is_private}")
PYEOF
)
                IFS=$'\t' read -r PKG_NAME PKG_VERSION PKG_PRIVATE <<< "${PKG_META}"
                if [[ -n "${PKG_NAME}" ]] && [[ "${PKG_PRIVATE}" != "true" ]] && [[ -n "${PKG_VERSION}" ]]; then
                    PKG_SPEC="${PKG_NAME}@${PKG_VERSION}"
                elif [[ -n "${PKG_NAME}" ]] && [[ "${PKG_PRIVATE}" != "true" ]]; then
                    PKG_SPEC="${PKG_NAME}"
                fi
            fi

            # Derive likely package name from module basename (e.g. claude_native.node -> claude-native)
            PKG_GUESS=$(echo "${mod_name%.node}" | tr '_' '-')
            for PKG in "${PKG_SPEC}" "${PKG_GUESS}" "node-pty" "claude-native" "@anthropic-ai/claude-native"; do
                [[ -z "${PKG}" ]] && continue
                if (cd "${NPM_WORK}" && npm install --omit=dev "${PKG}" 2>/dev/null); then
                    CANDIDATE=$(find "${NPM_WORK}" -name "${mod_name}" -type f 2>/dev/null | head -1 || true)
                    if [[ -n "${CANDIDATE}" ]]; then
                        DOWNLOAD_PATH="${WORK_DIR}/linux-${mod_name}"
                        cp "${CANDIDATE}" "${DOWNLOAD_PATH}"
                        LINUX_NODE="${DOWNLOAD_PATH}"
                        log "  Source: npm package ${PKG}"
                        break
                    fi
                fi
            done
            rm -rf "${NPM_WORK}"
        fi

        # FAIL hard if no replacement found — do not package known-broken binaries
        if [[ -z "${LINUX_NODE}" ]]; then
            log "  FAILED: No Linux replacement found for ${mod_name}"
            log "  To fix: compile or obtain a Linux build of this module and place it at:"
            log "          ${PATCHES_RUNTIME_DIR}/${mod_name}"
            REPLACE_FAILED=1
            continue
        fi

        # Validate replacement is Linux ELF x86-64
        LINUX_FILE_OUT=$(file "${LINUX_NODE}")
        if ! echo "${LINUX_FILE_OUT}" | grep -q "ELF.*x86-64"; then
            die "Replacement for ${mod_name} is not Linux x86-64 ELF.
Got: ${LINUX_FILE_OUT}
Source: ${LINUX_NODE}
Place a correct Linux .node file at: ${PATCHES_RUNTIME_DIR}/${mod_name}"
        fi

        # Report ABI type (informational — helps diagnose future version mismatches)
        if command -v nm >/dev/null 2>&1; then
            if nm -D "${LINUX_NODE}" 2>/dev/null | grep -q 'napi_module_register'; then
                log "  ABI: N-API (ABI-stable across Node.js versions)"
            elif nm -D "${LINUX_NODE}" 2>/dev/null | grep -q 'node_module_register\|NODE_MODULE_VERSION'; then
                log "  ABI: Non-NAPI (pinned to specific Node ABI — verify Electron v${ELECTRON_VERSION} compatibility)"
            fi
        fi

        # Replace
        cp "${LINUX_NODE}" "${win_path}"
        chmod 755 "${win_path}"
        SHA256=$(sha256sum "${win_path}" | awk '{print $1}')
        log "  Replaced: ${win_path}"
        log "  SHA256:   ${SHA256}"
    done

    if [[ "${REPLACE_FAILED}" -ne 0 ]]; then
        die "One or more native modules could not be replaced with Linux equivalents.
The build has been aborted to prevent publishing an RPM with non-functional binaries.
See above for which modules failed and how to supply replacements."
    fi

    log "All native modules replaced successfully."
fi

# ============================================================
# STEP 3: Neutralize Windows-only startup hooks
# ============================================================
log "=== Step 3: Windows startup patches ==="

SQUIRREL_CHECK="${PATCHED_DIR}/node_modules/electron-squirrel-startup/index.js"
if [[ -f "${SQUIRREL_CHECK}" ]]; then
    log "Neutralizing Squirrel auto-updater startup check..."
    echo "module.exports = false;" > "${SQUIRREL_CHECK}"
fi

# ============================================================
# STEP 4: Stamp Linux packaging info into package.json
# ============================================================
PKG_JSON="${PATCHED_DIR}/package.json"
if [[ -f "${PKG_JSON}" ]]; then
    python3 - "${PKG_JSON}" "${VERSION}" <<'PYEOF'
import json, sys
path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    pkg = json.load(f)
pkg.setdefault('linuxPackaging', {
    'platform': 'fedora',
    'packagedBy': 'claude-desktop-fedora',
    'packagedVersion': version
})
with open(path, 'w') as f:
    json.dump(pkg, f, indent=2)
    f.write('\n')
PYEOF
    log "package.json stamped with Linux packaging metadata."
fi

# ============================================================
# STEP 5: Write patch manifest
# ============================================================
NATIVE_REPLACED="false"
[[ ${#WIN_NODES[@]} -gt 0 && "${SKIP_NATIVE_PATCH}" != "1" ]] && NATIVE_REPLACED="true"

cat > "${WORK_DIR}/patch-manifest.json" <<EOF
{
  "version": "${VERSION}",
  "electron_version": "${ELECTRON_VERSION}",
  "patched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "linux_electron_dir": "${ELECTRON_LINUX_DIR}",
  "native_modules_found": ${#WIN_NODES[@]},
  "native_bindings_replaced": ${NATIVE_REPLACED},
  "squirrel_neutralized": $([ -f "${SQUIRREL_CHECK:-/nonexistent}" ] && echo "true" || echo "false")
}
EOF
log "Patch manifest written: ${WORK_DIR}/patch-manifest.json"
log "Done. Patched app: ${PATCHED_DIR}"
log "      Linux Electron: ${ELECTRON_LINUX_DIR}"
