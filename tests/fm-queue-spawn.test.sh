#!/usr/bin/env bash
# Full queue -> fm-spawn -> task metadata/backlog/launch delivery regression.
# The backend and agent are fixture executables; all lifecycle scripts are real.
set -u
# Build the fixture without the invoking gate's runtime controls.
for inherited in $(compgen -v FM_); do unset "$inherited"; done
unset NO_MISTAKES_GATE
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh" || exit 1
declare -F fm_test_tmproot >/dev/null || fail 'fixture initialization failed (process identity unavailable)'
TMP_ROOT=$(fm_test_tmproot fm-queue-spawn) || fail 'fixture root unavailable'
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
export FM_HOME="$TMP_ROOT/home"
fm_test_spawn_home "$FM_HOME" codex
fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/slot" fm/queue-test
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/tools" codex gh-axi)
# Keep the ordinary spawn fixture but expose a live parked worker too.
cp "$fakebin/tmux" "$fakebin/tmux-fixture"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *pane_current_command*) printf 'claude\n'; exit 0 ;;
esac
if [ "${1:-}" = new-window ] && [ -n "${FM_QUEUE_WINDOW_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_QUEUE_WINDOW_LOG"
fi
exec "${0%/*}/tmux-fixture" "$@"
SH
chmod +x "$fakebin/tmux"
mkdir -p "$FM_HOME/user-home"
export HOME="$FM_HOME/user-home" CLAUDE_CONFIG_DIR=''
export PATH="$fakebin:$PATH" FM_SPAWN_NO_GUARD=1
export FM_FAKE_PANE_PATH="$TMP_ROOT/slot" FM_FAKE_DUPLICATE_WINDOW=fm-parked
export FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" TMUX=fake,1,0
"$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null || fail 'away entry'
fm_write_meta "$FM_HOME/state/parked.meta" "window=fm:fm-parked" "worktree=$TMP_ROOT/project" "project=$TMP_ROOT/project" "kind=ship" "harness=claude"
"$ROOT/bin/fm-tasks-axi.sh" add clear 'queued integration task' >/dev/null || fail 'queued row'
fm_test_spawn_brief "$FM_HOME" clear
"$ROOT/bin/fm-queue-pull.sh" prepare clear "$TMP_ROOT/project" --mode no-mistakes --yolo off --harness codex || fail 'prepare'
# No direct tick: the idle watcher must discover and attempt the queued work.
watch_pid=
cleanup() {
  if [ -n "$watch_pid" ]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
start_watch() {
  FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watcher.out" 2> "$TMP_ROOT/watcher.err" &
  watch_pid=$!
}
wait_report() {
  local expected=$1 rearm=${2:-no} n
  for ((n=0; n<300; n++)); do
    if [ -f "$FM_HOME/state/.queue-pull-report" ] &&
       grep -F "$expected" "$FM_HOME/state/.queue-pull-report" >/dev/null; then return 0; fi
    if [ "$rearm" = yes ] && ! kill -0 "$watch_pid" 2>/dev/null; then
      wait "$watch_pid" || fail 'watcher notification failed'
      watch_pid=
      [ -s "$TMP_ROOT/watcher.out" ] || fail 'watcher exited without a notification'
      start_watch
    fi
    sleep 0.1
  done
  fail "watcher did not report $expected: $(cat "$FM_HOME/state/.queue-pull-errors" "$TMP_ROOT/watcher.err" 2>/dev/null)"
}
start_watch
wait_report 'clear: spawn refused'
[ ! -f "$FM_HOME/state/clear.meta" ] || fail 'uncertain worker released spend'
assert_contains "$(cat "$FM_HOME/state/.queue-pull-report")" 'caps concurrent workers at 1' 'refusal was not the spend cap'
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
watch_pid=
pass 'idle watcher attempts prepared work and preserves the cap for uncertain workers'

"$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" parked --state idle --source claude-hook --event stop >/dev/null || fail 'parked hook'
printf 'paused [at=%s]: waiting for an external condition\n' "$(date +%s)" > "$FM_HOME/state/parked.status"
assert_contains "$("$ROOT/bin/fm-crew-state.sh" parked)" 'state: paused' 'real crew-state did not reconcile the parked endpoint'
# Advance only the persisted timer deadline, keeping the queued plan unchanged.
printf '0\n' > "$FM_HOME/state/.queue-pull-last"
fm_touch_epoch 0 "$FM_HOME/state/.queue-pull-last"
start_watch
# A stopped watcher first delivers its downtime notification and exits. The
# supervisor normally rearms it after consuming that notification.
for ((n=0; n<300; n++)); do
  if ! kill -0 "$watch_pid" 2>/dev/null; then
    wait "$watch_pid" || fail 'watcher recovery notification failed'
    watch_pid=
    assert_contains "$(cat "$TMP_ROOT/watcher.out")" 'check: rearm-resurface' 'unexpected watcher exit'
    start_watch
    break
  fi
  sleep 0.1
done
wait_report 'clear: started through fm-spawn'
report=$(cat "$FM_HOME/state/.queue-pull-report")
assert_contains "$report" 'clear: started through fm-spawn' 'queue did not launch through real spawn'
[ -f "$FM_HOME/state/clear.meta" ] || fail 'spawn metadata missing'
[ -s "$TMP_ROOT/launch.log" ] || fail 'no native launch delivery'
assert_contains "$("$ROOT/bin/fm-tasks-axi.sh" show clear)" 'state: in_flight' 'backlog did not start'
pass 'idle watcher retries real spawn and starts queued work beside a parked worker at cap one'

kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
watch_pid=

# A separate home makes the four-place limit independent of the cap-one case.
export FM_HOME="$TMP_ROOT/four-home"
fm_test_spawn_home "$FM_HOME" codex
export FM_FAKE_LAUNCH_LOG="$TMP_ROOT/four-launch.log"
export FM_QUEUE_WINDOW_LOG="$TMP_ROOT/four-windows.log"
export FM_FAKE_DUPLICATE_WINDOW=$'fm-liveone\nfm-livetwo\nfm-livethree\nfm-releasing'
"$ROOT/bin/fm-afk-contract.sh" enter --spend 4 >/dev/null || fail 'four-place away entry'
mkdir -p "$TMP_ROOT/preserved"
for worker in liveone livetwo livethree releasing; do
  mkdir -p "$TMP_ROOT/$worker"
  printf 'unfinished work for %s\n' "$worker" > "$TMP_ROOT/$worker/unfinished.txt"
  fm_write_meta "$FM_HOME/state/$worker.meta" "window=fm:fm-$worker" \
    "worktree=$TMP_ROOT/$worker" "project=$TMP_ROOT/project" 'kind=ship' 'harness=claude'
  "$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" "$worker" --state busy --source claude-hook --event submit >/dev/null || fail 'live worker hook'
  printf 'working [at=%s]: unfinished work\n' "$(date +%s)" > "$FM_HOME/state/$worker.status"
  assert_contains "$("$ROOT/bin/fm-crew-state.sh" "$worker")" 'state: working' 'worker was not genuinely live'
done
for worker in liveone livetwo livethree; do
  cp "$FM_HOME/state/$worker.meta" "$TMP_ROOT/preserved/$worker.meta"
  cp "$FM_HOME/state/$worker.status" "$TMP_ROOT/preserved/$worker.status"
  cp -R "$TMP_ROOT/$worker" "$TMP_ROOT/preserved/$worker"
done
for queued in nextone nexttwo; do
  "$ROOT/bin/fm-tasks-axi.sh" add "$queued" 'four-place queued work' >/dev/null || fail 'four-place queued row'
  fm_test_spawn_brief "$FM_HOME" "$queued"
  "$ROOT/bin/fm-queue-pull.sh" prepare "$queued" "$TMP_ROOT/project" --mode no-mistakes --yolo off --harness codex || fail 'four-place prepare'
done

# Re-arm notification exits as the supervisor does across timer passes.
start_watch
wait_report 'caps concurrent workers at 4' yes
[ ! -e "$FM_HOME/state/nextone.meta" ] && [ ! -e "$FM_HOME/state/nexttwo.meta" ] || fail 'launched at full capacity'
[ ! -s "$FM_FAKE_LAUNCH_LOG" ] || fail 'backend launched at full capacity'
"$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" releasing --state idle --source claude-hook --event stop >/dev/null || fail 'release hook'
printf 'paused [at=%s]: waiting for an external condition\n' "$(date +%s)" > "$FM_HOME/state/releasing.status"
assert_contains "$("$ROOT/bin/fm-crew-state.sh" releasing)" 'state: paused' 'release was not reconciled'
printf '0\n' > "$FM_HOME/state/.queue-pull-last"
fm_touch_epoch 0 "$FM_HOME/state/.queue-pull-last"
wait_report 'started through fm-spawn' yes

if [ -f "$FM_HOME/state/nextone.meta" ] && [ ! -f "$FM_HOME/state/nexttwo.meta" ]; then
  launched=nextone remaining=nexttwo
elif [ -f "$FM_HOME/state/nexttwo.meta" ] && [ ! -f "$FM_HOME/state/nextone.meta" ]; then
  launched=nexttwo remaining=nextone
else
  fail 'one freed place did not start exactly one queued job'
fi
launch_bytes=$(cksum < "$FM_FAKE_LAUNCH_LOG")
# The backend logs each native launch payload, which may contain newlines.
# A separate log records each backend window creation, one per launch.
[ "$(wc -l < "$FM_QUEUE_WINDOW_LOG" | tr -d ' ')" -eq 1 ] || fail 'not exactly one backend launch'
assert_contains "$("$ROOT/bin/fm-tasks-axi.sh" show "$launched")" 'state: in_flight' 'launched row not started'
assert_contains "$("$ROOT/bin/fm-tasks-axi.sh" show "$remaining")" 'state: queued' 'second row left queue'

# The first pass defers the second item after its one successful launch.
# The next timer must actually try it and record the capacity refusal.
printf '0\n' > "$FM_HOME/state/.queue-pull-last"
fm_touch_epoch 0 "$FM_HOME/state/.queue-pull-last"
wait_report "$remaining: spawn refused" yes
assert_contains "$(cat "$FM_HOME/state/.queue-pull-report")" 'caps concurrent workers at 4 and 4 ordinary task(s)' 'second pass did not preserve the four-worker cap'
[ ! -f "$FM_HOME/state/$remaining.meta" ] || fail 'second queued job started'
[ "$(cksum < "$FM_FAKE_LAUNCH_LOG")" = "$launch_bytes" ] || fail 'duplicate backend launch on second timer pass'
[ "$(wc -l < "$FM_QUEUE_WINDOW_LOG" | tr -d ' ')" -eq 1 ] || fail 'duplicate backend window on second timer pass'
metas=("$FM_HOME/state/"*.meta)
[ "${#metas[@]}" -eq 5 ] || fail 'unexpected worker count (four counted plus one parked)'
for worker in liveone livetwo livethree; do
  cmp "$FM_HOME/state/$worker.meta" "$TMP_ROOT/preserved/$worker.meta" || fail 'live metadata disturbed'
  cmp "$FM_HOME/state/$worker.status" "$TMP_ROOT/preserved/$worker.status" || fail 'live status disturbed'
  diff -r "$TMP_ROOT/$worker" "$TMP_ROOT/preserved/$worker" || fail 'unfinished worktree disturbed'
done
[ -f "$TMP_ROOT/releasing/unfinished.txt" ] || fail 'freed worker unfinished work deleted'
pass 'a freed place at the limit of four starts exactly one queued job through the idle watcher, with no duplicate and no unfinished worker disturbed'
