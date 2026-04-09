#!/usr/bin/env bash
# install-smoke.sh — Validate installed package structure (no display needed)
#
# Run after: sudo dnf install ./claude-desktop-*.rpm
# Does NOT launch a GUI window. Validates files, links, and binary health.

set -euo pipefail

PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
section() { printf '\n=== %s ===\n' "$*"; }

section "Installed files"

# Launcher
if [[ -x /usr/bin/claude-desktop ]]; then
    pass "/usr/bin/claude-desktop is executable"
else
    fail "/usr/bin/claude-desktop missing or not executable"
fi

# Desktop entry
if [[ -f /usr/share/applications/claude-desktop.desktop ]]; then
    pass "/usr/share/applications/claude-desktop.desktop exists"
else
    fail ".desktop file missing"
fi

# App binary
if [[ -f /opt/claude-desktop/claude ]]; then
    pass "/opt/claude-desktop/claude binary exists"
else
    fail "/opt/claude-desktop/claude missing"
fi

# app.asar
if [[ -f /opt/claude-desktop/resources/app.asar ]]; then
    pass "resources/app.asar present"
    ASAR_SIZE=$(du -sb /opt/claude-desktop/resources/app.asar | cut -f1)
    if [[ "${ASAR_SIZE}" -gt 1000000 ]]; then
        pass "app.asar size looks reasonable (${ASAR_SIZE} bytes)"
    else
        fail "app.asar suspiciously small (${ASAR_SIZE} bytes)"
    fi
else
    fail "resources/app.asar missing"
fi

section "Binary health"

# Check it's a Linux ELF binary
if file /opt/claude-desktop/claude 2>/dev/null | grep -q "ELF.*x86-64"; then
    pass "claude binary is Linux x86-64 ELF"
else
    fail "claude binary is not Linux x86-64 ELF"
    file /opt/claude-desktop/claude >&2 || true
fi

# No Windows PE files in critical locations
if find /opt/claude-desktop -name "*.exe" 2>/dev/null | grep -q .; then
    fail "Found .exe files in install dir (Windows artifacts not cleaned)"
    find /opt/claude-desktop -name "*.exe" >&2
else
    pass "No .exe files found"
fi

# No .dll files
if find /opt/claude-desktop -name "*.dll" 2>/dev/null | grep -q .; then
    fail "Found .dll files in install dir"
else
    pass "No .dll files found"
fi

section "Native module check"

NODE_FILES=$(find /opt/claude-desktop -name "*.node" 2>/dev/null || true)
if [[ -n "${NODE_FILES}" ]]; then
    while IFS= read -r f; do
        if file "${f}" 2>/dev/null | grep -q "ELF.*x86-64"; then
            pass "Native module is Linux ELF: $(basename "${f}")"
        else
            fail "Native module is NOT Linux ELF: ${f}"
            file "${f}" >&2 || true
        fi
    done <<< "${NODE_FILES}"
else
    echo "  NOTE: No .node files found (may be OK if app has no native modules)"
fi

section "Desktop integration"

# Validate desktop file
if command -v desktop-file-validate >/dev/null 2>&1; then
    if desktop-file-validate /usr/share/applications/claude-desktop.desktop 2>/dev/null; then
        pass "desktop-file-validate passed"
    else
        fail "desktop-file-validate reported issues"
    fi
fi

# Check desktop file has required fields
for field in "Exec=" "Icon=" "Name=" "Type=Application"; do
    if grep -q "${field}" /usr/share/applications/claude-desktop.desktop; then
        pass ".desktop has ${field}"
    else
        fail ".desktop missing ${field}"
    fi
fi

section "Launcher script"

# Launcher should reference correct binary
if grep -q "/opt/claude-desktop/claude" /usr/bin/claude-desktop; then
    pass "Launcher references correct binary path"
else
    fail "Launcher does not reference /opt/claude-desktop/claude"
fi

# Launcher should set Ozone flags
if grep -q "ozone" /usr/bin/claude-desktop; then
    pass "Launcher contains Wayland/Ozone flags"
else
    fail "Launcher missing Ozone/Wayland flags"
fi

section "Summary"
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
    echo ""
    echo "SMOKE TEST FAILED: ${FAIL} check(s) failed."
    exit 1
else
    echo ""
    echo "SMOKE TEST PASSED."
    exit 0
fi
