#!/usr/bin/env bash
# launch-smoke.sh — Attempt a headless launch and check for startup errors
#
# Starts claude-desktop directly (not via timeout wrapper) and polls the actual
# app PID so we can distinguish "still running after N seconds" from "crashed".
#
# Requires: Xvfb or a running display.
# Run AFTER install-smoke.sh passes.

set -euo pipefail

TIMEOUT="${LAUNCH_TIMEOUT:-10}"
POLL_INTERVAL=1
PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== Launch smoke test (${TIMEOUT}s timeout) ==="

# --- display setup ---
if [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    if command -v Xvfb >/dev/null 2>&1; then
        echo "  Starting Xvfb..."
        Xvfb :99 -screen 0 1024x768x24 &
        XVFB_PID=$!
        export DISPLAY=:99
        sleep 1
    else
        echo "  No display available and Xvfb not installed — skipping launch test"
        echo "  Install: sudo dnf install xorg-x11-server-Xvfb"
        exit 0
    fi
fi

# --- launch ---
LOG_FILE=$(mktemp /tmp/claude-launch-XXXXXX.log)
echo "  Launching /usr/bin/claude-desktop (polling up to ${TIMEOUT}s)..."
echo "  Stderr log: ${LOG_FILE}"

/usr/bin/claude-desktop \
    --disable-gpu \
    --no-sandbox \
    2>"${LOG_FILE}" &
APP_PID=$!
echo "  App PID: ${APP_PID}"

# --- poll the app's actual PID ---
ELAPSED=0
APP_EXITED=0
APP_EXIT_CODE=0

while [[ "${ELAPSED}" -lt "${TIMEOUT}" ]]; do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        # Process has exited — capture its exit code
        wait "${APP_PID}" 2>/dev/null && APP_EXIT_CODE=0 || APP_EXIT_CODE=$?
        APP_EXITED=1
        break
    fi
    sleep "${POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# --- evaluate result ---
if [[ "${APP_EXITED}" -eq 0 ]]; then
    # Still running after TIMEOUT seconds — that is the success condition
    pass "Process still alive after ${TIMEOUT}s (did not crash on startup)"
    kill "${APP_PID}" 2>/dev/null || true
    wait "${APP_PID}" 2>/dev/null || true
else
    # Process exited before the timeout — check whether it was clean
    echo "  Process exited after ${ELAPSED}s with code ${APP_EXIT_CODE}"
    if [[ "${APP_EXIT_CODE}" -eq 0 ]]; then
        # exit 0 before timeout is unusual for a GUI app but not necessarily wrong
        pass "Process exited cleanly (exit 0)"
    else
        fail "Process crashed with exit code ${APP_EXIT_CODE} after ${ELAPSED}s"
        echo "  Last 30 lines of stderr log:"
        tail -30 "${LOG_FILE}" >&2 || true
    fi
fi

# --- log analysis ---
if [[ -s "${LOG_FILE}" ]]; then
    if grep -qi "SIGILL\|illegal instruction" "${LOG_FILE}"; then
        fail "SIGILL detected — binary incompatibility with this CPU"
    elif grep -qi "cannot open shared object\|error while loading shared" "${LOG_FILE}"; then
        fail "Missing shared library:"
        grep -i "cannot open shared object\|error while loading shared" "${LOG_FILE}" >&2 || true
    elif grep -qi "Exiting GPU process due to errors" "${LOG_FILE}" && [[ "${PASS}" -gt 0 ]]; then
        echo "  NOTE: GPU process error (expected with --disable-gpu in some Electron versions)"
    else
        pass "No fatal errors detected in stderr log"
    fi
else
    pass "Stderr log is empty (no error output)"
fi

# --- cleanup ---
rm -f "${LOG_FILE}"
[[ -n "${XVFB_PID:-}" ]] && kill "${XVFB_PID}" 2>/dev/null || true

echo ""
echo "Passed: ${PASS}, Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
