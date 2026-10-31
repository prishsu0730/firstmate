#!/usr/bin/env bash
# Shared away spend classification through the crew-state executable boundary.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worker-spend-lib.sh
. "$ROOT/bin/fm-worker-spend-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-spend)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state"
cat > "$TMP_ROOT/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ "$FM_CREW_STATE_NO_FORGE" = 1 ] || exit 1
[ "$1" = test-worker ] || exit 1
printf 'state: %s · source: run-step · fixture\n' "$SPEND_VERDICT"
exit "${SPEND_EXIT:-0}"
SH
chmod +x "$TMP_ROOT/bin/fm-crew-state.sh"
for verdict in parked paused 'done'; do
  SPEND_VERDICT=$verdict fm_worker_spend_parked "$TMP_ROOT/bin" "$TMP_ROOT/state" test-worker || fail "$verdict consumed spend capacity"
done
for verdict in working unknown conflict blocked failed; do
  if SPEND_VERDICT=$verdict fm_worker_spend_parked "$TMP_ROOT/bin" "$TMP_ROOT/state" test-worker; then
    fail "$verdict incorrectly released spend capacity"
  fi
done
if SPEND_VERDICT=parked SPEND_EXIT=1 fm_worker_spend_parked "$TMP_ROOT/bin" "$TMP_ROOT/state" test-worker; then
  fail 'failed current-state read released spend capacity'
fi
pass 'parked, paused, and done release spend; active and uncertain workers count'
