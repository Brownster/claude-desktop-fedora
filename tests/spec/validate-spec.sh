#!/usr/bin/env bash
# validate-spec.sh — Static validation of installed package metadata

set -euo pipefail

PASS=0; FAIL=0

pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== RPM spec / package validation ==="

# Check package is installed
if rpm -q claude-desktop >/dev/null 2>&1; then
    PKG_VERSION=$(rpm -q --queryformat '%{VERSION}' claude-desktop)
    PKG_RELEASE=$(rpm -q --queryformat '%{RELEASE}' claude-desktop)
    pass "Package installed: claude-desktop-${PKG_VERSION}-${PKG_RELEASE}"
else
    echo "claude-desktop is not installed — skipping installed-package checks"
    # Still validate spec file if present
    SPEC_FILE="packaging/fedora/claude-desktop.spec"
    if [[ -f "${SPEC_FILE}" ]]; then
        pass "Spec file exists"
        # Check required spec fields
        for field in "^Name:" "^Version:" "^Release:" "^Summary:" "^License:" "^BuildArch:" "^%install" "^%files"; do
            if grep -qP "${field}" "${SPEC_FILE}"; then
                pass "Spec has ${field}"
            else
                fail "Spec missing ${field}"
            fi
        done
    fi
    echo ""; echo "Passed: ${PASS}, Failed: ${FAIL}"
    if [[ "${FAIL}" -eq 0 ]]; then exit 0; else exit 1; fi
fi

# Installed package checks
echo ""
echo "--- Package metadata ---"
rpm -qi claude-desktop

echo ""
echo "--- Dependency check ---"
if rpm -qR claude-desktop | grep -q "gtk3"; then
    pass "gtk3 in requirements"
else
    fail "gtk3 not listed in requirements"
fi

if rpm -qR claude-desktop | grep -q "nss"; then
    pass "nss in requirements"
else
    fail "nss not in requirements"
fi

echo ""
echo "--- Scriptlet check ---"
if rpm -q --scripts claude-desktop | grep -q "update-desktop-database"; then
    pass "post-install updates desktop database"
else
    fail "post-install missing update-desktop-database"
fi

echo ""
echo "Passed: ${PASS}, Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
