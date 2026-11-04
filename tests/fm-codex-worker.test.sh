#!/usr/bin/env bash
# Portable launch-exit proof with real child processes, no vendor name mocks.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
TMP_ROOT=$(fm_test_tmproot fm-codex-worker)
mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/data/worker" "$TMP_ROOT/tasktmp"
WORKER="$ROOT/bin/fm-codex-worker.sh"
printf 'harness=codex\nspawn_gen=s-test\nkind=scout\n' > "$TMP_ROOT/state/worker.meta"
printf 'tasktmp=%s\n' "$TMP_ROOT/tasktmp" >> "$TMP_ROOT/state/worker.meta"
printf 'done [at=1793790163]: report saved\n' > "$TMP_ROOT/state/worker.status"
printf 'saved report\n' > "$TMP_ROOT/data/worker/report.md"
released() { "$WORKER" released "$TMP_ROOT/state" worker; }
run() { "$WORKER" run "$TMP_ROOT/state" worker s-test "$@"; }
released && fail 'status alone released worker'
run bash -c 'exit 3' && fail 'failed child accepted'
released && fail 'failed child released worker'
run bash -c 'exit 0' || fail 'successful child failed'
released || fail 'completed scout retained capacity'
printf 'unlanded\n' > "$TMP_ROOT/unlanded"
mkfifo "$TMP_ROOT/release"
run bash -c 'touch "$1/started"; read -r value < "$1/release"' _ "$TMP_ROOT" &
child=$!
for ((i=0; i<100; i++)); do
  [ ! -f "$TMP_ROOT/started" ] || break
  sleep 0.1
done
[ -f "$TMP_ROOT/started" ] || fail 'child did not start'
released && fail 'running child reused prior receipt'
printf 'finish\n' > "$TMP_ROOT/release"
wait "$child" || fail 'child failed'
released || fail 'returned child did not release'
[ "$(cat "$TMP_ROOT/unlanded")" = unlanded ] || fail 'unlanded file changed'
printf 'working: resumed\n' >> "$TMP_ROOT/state/worker.status"
released && fail 'new working declaration ignored'
printf 'done: report saved\n' >> "$TMP_ROOT/state/worker.status"
printf 'spawn_gen=s-new\n' >> "$TMP_ROOT/state/worker.meta"
released && fail 'old launch receipt accepted'
pass 'successful current launch plus completion releases; running, failed, resumed and stale launches retain occupancy'
