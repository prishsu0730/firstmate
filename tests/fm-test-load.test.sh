#!/usr/bin/env bash
# Behavior tests for the shared heavy-test admission gate, without host load.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-load)
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/python3" <<'SH'
#!/bin/sh
n=$(cat "$LOAD_COUNT" 2>/dev/null || echo 0)
echo $((n + 1)) > "$LOAD_COUNT"
case "$LOAD_MODE" in
  clear) exit 0 ;;
  cool) [ "$n" -ge 2 ] && exit 0; exit 1 ;;
  busy) exit 1 ;;
  error) exit 2 ;;
esac
SH
cat > "$TMP_ROOT/fakebin/sleep" <<'SH'
#!/bin/sh
echo sleep >> "$LOAD_SLEEPS"
SH
chmod +x "$TMP_ROOT/fakebin/"*
REAL_PATH=$PATH
export PATH="$TMP_ROOT/fakebin:$PATH" LOAD_COUNT="$TMP_ROOT/count" LOAD_SLEEPS="$TMP_ROOT/sleeps"
export FM_TEST_LOAD_INTERVAL=1 FM_TEST_LOAD_WAIT=2
run_gate() { bash "$ROOT/bin/fm-test-load.sh"; }
export LOAD_MODE=clear
run_gate || fail 'idle machine was refused'
[ ! -e "$LOAD_SLEEPS" ] || fail 'idle gate slept'
export LOAD_MODE=cool
printf '0\n' > "$LOAD_COUNT"
run_gate || fail 'gate did not admit after load cleared'
[ "$(wc -l < "$LOAD_SLEEPS")" -eq 2 ] || fail 'gate did not wait for both busy samples'
export LOAD_MODE=busy
if run_gate; then fail 'persistent load must fail, not launch heavy work'; fi
export LOAD_MODE=error
if run_gate; then fail 'unreadable load must fail closed'; fi
FM_TEST_LOAD_INTERVAL=0 run_gate && fail 'invalid interval accepted'
for threshold in nan 0 -1 invalid; do
  if PATH="$REAL_PATH" FM_TEST_LOAD_MAX="$threshold" run_gate; then
    fail "invalid threshold accepted: $threshold"
  fi
done
pass 'idle, cooling, persistent, unreadable load and invalid settings'
