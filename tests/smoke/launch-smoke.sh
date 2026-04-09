#!/usr/bin/env bash
# launch-smoke.sh — Attempt a headless launch and check for startup errors
#
# Requires: Xvfb or a running display (or --headless mode)
# Run AFTER install-smoke.sh passes.

set -euo pipefail

TIMEOUT="${LAUNCH_TIMEOUT:-10}"
PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== Launch smoke test (${TIMEOUT}s timeout) ==="

# Check if display available (or Xvfb)
if [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    if command -v Xvfb >/dev/null 2>&1; then
        echo "  Starting Xvfb..."
        Xvfb :99 -screen 0 1024x768x24 &
        XVFB_PID=$!
        export DISPLAY=:99
        sleep 1
        KILL_XVFB=1
    else
        echo "  No display available and Xvfb not installed — skipping launch test"
        echo "  Install: sudo dnf install xorg-x11-server-Xvfb"
        exit 0
    fi
fi

# Attempt launch
LOG_FILE=$(mktemp /tmp/claude-launch-XXXXXX.log)
echo "  Launching claude-desktop (timeout: ${TIMEOUT}s)..."
echo "  Log: ${LOG_FILE}"

timeout "${TIMEOUT}" /usr/bin/claude-desktop \
    --disable-gpu \
    --no-sandbox \
    2>"${LOG_FILE}" &
CLAUDE_PID=$!

sleep "${TIMEOUT}"

# Check if process is still running (good sign — means it didn't crash immediately)
if kill -0 "${CLAUDE_PID}" 2>/dev/null; then
    pass "Process still running after ${TIMEOUT}s (did not crash on startup)"
    kill "${CLAUDE_PID}" 2>/dev/null || true
    wait "${CLAUDE_PID}" 2>/dev/null || true
else
    # Process exited — was it expected (e.g. --version) or a crash?
    EXIT_CODE=$?
    if [[ "${EXIT_CODE}" -eq 0 ]]; then
        pass "Process exited cleanly (exit 0)"
    else
        fail "Process crashed with exit code ${EXIT_CODE}"
        echo "  Last 20 lines of log:"
        tail -20 "${LOG_FILE}" >&2 || true
    fi
fi

# Check log for critical errors
if grep -qi "SIGILL\|illegal instruction\|Illegal instruction" "${LOG_FILE}"; then
    fail "SIGILL detected — binary incompatibility"
elif grep -qi "cannot open shared object\|libnotfound\|error while loading" "${LOG_FILE}"; then
    fail "Missing shared library detected"
    grep -i "cannot open shared object\|error while loading" "${LOG_FILE}" >&2 || true
else
    pass "No critical startup errors in log"
fi

# Cleanup
[[ -f "${LOG_FILE}" ]] && rm -f "${LOG_FILE}"
[[ -n "${KILL_XVFB:-}" ]] && kill "${XVFB_PID}" 2>/dev/null || true

echo ""
echo "Passed: ${PASS}, Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
