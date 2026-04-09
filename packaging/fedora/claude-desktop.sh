#!/usr/bin/env bash
# claude-desktop.sh — Launcher wrapper for Claude Desktop
#
# Installed as /usr/bin/claude-desktop
# Sets Electron flags for Wayland/X11 compatibility on Fedora

CLAUDE_BIN="/opt/claude-desktop/claude"

if [[ ! -x "${CLAUDE_BIN}" ]]; then
    echo "claude-desktop: binary not found at ${CLAUDE_BIN}" >&2
    echo "Try reinstalling: sudo dnf reinstall claude-desktop" >&2
    exit 1
fi

# ---- Wayland / display detection ----
# KDE Wayland has been unreliable for pointer/input handling in this build, so
# prefer X11 there unless the user explicitly overrides the platform choice.
OZONE_FLAGS=()
if [[ -n "${CLAUDE_OZONE_PLATFORM:-}" ]]; then
    case "${CLAUDE_OZONE_PLATFORM}" in
        x11|wayland|auto)
            OZONE_FLAGS+=("--ozone-platform=${CLAUDE_OZONE_PLATFORM}")
            ;;
        *)
            echo "claude-desktop: unsupported CLAUDE_OZONE_PLATFORM='${CLAUDE_OZONE_PLATFORM}' (expected x11, wayland, or auto)" >&2
            exit 1
            ;;
    esac
elif [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && [[ "${XDG_CURRENT_DESKTOP:-}" =~ KDE ]]; then
    OZONE_FLAGS+=("--ozone-platform=x11")
else
    OZONE_FLAGS+=(
        "--enable-features=UseOzonePlatform,WaylandWindowDecorations"
        "--ozone-platform-hint=auto"
    )
fi

# ---- Sandbox flags ----
# chrome-sandbox requires setuid root in the RPM. If it's missing or not setuid,
# disable the sandbox rather than crashing silently.
SANDBOX_FLAGS=()
SANDBOX_BIN="/opt/claude-desktop/chrome-sandbox"
if [[ ! -u "${SANDBOX_BIN}" ]]; then
    SANDBOX_FLAGS+=("--no-sandbox")
fi

# ---- GPU / rendering ----
# Disable GPU sandbox on systems where it causes startup crashes
GPU_FLAGS=()
if [[ "${CLAUDE_DISABLE_GPU:-0}" == "1" ]]; then
    GPU_FLAGS+=("--disable-gpu")
fi

# ---- User data directory ----
# Respect XDG Base Directory spec
export ELECTRON_USER_DATA_DIR="${CLAUDE_USER_DATA_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/Claude}"

# ---- Expose single-instance lock location ----
mkdir -p "${ELECTRON_USER_DATA_DIR}"

exec "${CLAUDE_BIN}" \
    "${OZONE_FLAGS[@]}" \
    "${SANDBOX_FLAGS[@]}" \
    "${GPU_FLAGS[@]}" \
    "$@"
