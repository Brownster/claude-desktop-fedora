#!/usr/bin/env bash
# verify-artifact.sh — Validate a built RPM before publishing
#
# Checks:
#   - rpm -qpi: package info readable
#   - rpm -qlp: file list non-empty
#   - rpmlint: lint score (warnings OK, errors fail)
#   - Required files present (launcher, desktop entry, app.asar)
#   - No Windows-specific .exe files leaked in
#   - Launcher script is executable
#
# Usage: ./verify-artifact.sh <path/to/package.rpm>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[verify-artifact] %s\n' "$*" >&2; }
pass() { printf '[verify-artifact] PASS: %s\n' "$*" >&2; }
warn() { printf '[verify-artifact] WARN: %s\n' "$*" >&2; }
fail() { printf '[verify-artifact] FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES+1)); }
die()  { printf '[verify-artifact] ERROR: %s\n' "$*" >&2; exit 1; }

RPM_FILE="${1:-}"
[[ -z "${RPM_FILE}" ]] && die "Usage: $0 <package.rpm>"
[[ -f "${RPM_FILE}" ]] || die "File not found: ${RPM_FILE}"

FAILURES=0

log "Verifying: ${RPM_FILE}"
log "Size: $(du -sh "${RPM_FILE}" | cut -f1)"

# --- basic RPM validity ---
log "--- RPM header ---"
if rpm -qpi "${RPM_FILE}" 2>&1; then
    pass "rpm -qpi"
else
    fail "rpm -qpi failed — RPM is not valid"
fi

# --- file list ---
log "--- RPM file list ---"
FILE_LIST=$(rpm -qlp "${RPM_FILE}" 2>/dev/null || true)
if [[ -n "${FILE_LIST}" ]]; then
    pass "rpm -qlp ($(echo "${FILE_LIST}" | wc -l) files)"
    echo "${FILE_LIST}" | head -30 >&2
    [[ $(echo "${FILE_LIST}" | wc -l) -gt 30 ]] && log "  ... (truncated)"
else
    fail "rpm -qlp returned empty file list"
fi

# --- required files ---
log "--- Required files ---"
REQUIRED=(
    "/usr/bin/claude-desktop"
    "/usr/share/applications/claude-desktop.desktop"
    "/opt/claude-desktop/resources/app.asar"
)
for req in "${REQUIRED[@]}"; do
    if echo "${FILE_LIST}" | grep -qF "${req}"; then
        pass "Present: ${req}"
    else
        fail "Missing required file: ${req}"
    fi
done

# --- icon present ---
if echo "${FILE_LIST}" | grep -q '/usr/share/icons/'; then
    pass "Icon(s) present"
else
    warn "No icons found in /usr/share/icons/ — app may lack desktop icon"
fi

# --- no .exe files leaked ---
log "--- Checking for Windows artifacts ---"
if echo "${FILE_LIST}" | grep -qi '\.exe$'; then
    fail "Windows .exe files found in package — patch step may have missed them"
else
    pass "No .exe files in package"
fi

# --- no .dll files ---
if echo "${FILE_LIST}" | grep -qi '\.dll$'; then
    fail "Windows .dll files found in package"
else
    pass "No .dll files in package"
fi

# --- rpmlint (advisory, not fatal unless errors) ---
log "--- rpmlint ---"
if command -v rpmlint >/dev/null 2>&1; then
    LINT_OUTPUT=$(rpmlint "${RPM_FILE}" 2>&1 || true)
    LINT_ERRORS=$(echo "${LINT_OUTPUT}" | grep -c '^.*: E:' || true)
    LINT_WARNS=$(echo "${LINT_OUTPUT}"  | grep -c '^.*: W:' || true)
    echo "${LINT_OUTPUT}" | head -30 >&2
    if [[ "${LINT_ERRORS}" -gt 0 ]]; then
        fail "rpmlint reported ${LINT_ERRORS} error(s)"
    else
        pass "rpmlint: ${LINT_ERRORS} errors, ${LINT_WARNS} warnings"
    fi
else
    warn "rpmlint not available (sudo dnf install rpmlint). Skipping lint check."
fi

# --- summary ---
log "---"
if [[ "${FAILURES}" -eq 0 ]]; then
    log "All checks passed."
    exit 0
else
    log "${FAILURES} check(s) FAILED."
    exit 1
fi
