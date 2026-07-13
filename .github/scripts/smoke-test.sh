#!/bin/bash
# Launch the built app and prove it survives startup.
#
# `codesign --verify` is not enough: it checks each signature in isolation, so an
# ad-hoc bundle whose Hardened Runtime forbids its own frameworks passes the check
# and then dies in dyld before main(). Only launching catches that.
set -uo pipefail

APP="${1:?usage: smoke-test.sh /path/to/FusionNotch.app}"
BIN="$APP/Contents/MacOS/FusionNotch"
LOG="$(mktemp -t fusionnotch-smoke)"
GRACE=10

test -x "$BIN" || { echo "no executable at $BIN"; exit 1; }

cleanup() {
  # The app has a run loop and does not act on SIGTERM, so never wait on it —
  # signal the group, give it a beat, then insist.
  kill -TERM -"$PID" 2>/dev/null
  sleep 1
  kill -KILL -"$PID" 2>/dev/null
  # mediaremote-adapter.pl puts itself in its own process group and so outlives the
  # group kill. Sweep by bundle path to catch it and anything else the app spawned.
  pkill -KILL -f "$APP" 2>/dev/null
  return 0
}

# Job control, so the app lands in its own process group.
set -m
"$BIN" >"$LOG" 2>&1 &
PID=$!
set +m
trap cleanup EXIT

sleep "$GRACE"

if kill -0 "$PID" 2>/dev/null; then
  echo "✅ still running after ${GRACE}s"
  exit 0
fi

wait "$PID" 2>/dev/null
STATUS=$?

echo "❌ exited during startup (status $STATUS)"
echo "--- launch log ---"
cat "$LOG"

# Name the failure we already shipped once, so the next person does not have to
# re-derive it from a dyld backtrace.
if grep -q "different Team IDs" "$LOG"; then
  echo
  echo "dyld rejected an embedded framework: the app is ad-hoc signed (no Team ID) but"
  echo "Hardened Runtime is on, so Library Validation refuses to map it. The bundle needs"
  echo "com.apple.security.cs.disable-library-validation in its entitlements."
fi

exit 1
