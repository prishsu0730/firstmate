#!/usr/bin/env bash
# Full queue -> fm-spawn -> task metadata/backlog/launch delivery regression.
# The backend and agent are fixture executables; all lifecycle scripts are real.
set -u
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
  local expected=$1 n
  for ((n=0; n<300; n++)); do
    if [ -f "$FM_HOME/state/.queue-pull-report" ] &&
       grep -F "$expected" "$FM_HOME/state/.queue-pull-report" >/dev/null; then return 0; fi
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
start_watch
wait_report 'clear: started through fm-spawn'
report=$(cat "$FM_HOME/state/.queue-pull-report")
assert_contains "$report" 'clear: started through fm-spawn' 'queue did not launch through real spawn'
[ -f "$FM_HOME/state/clear.meta" ] || fail 'spawn metadata missing'
[ -s "$TMP_ROOT/launch.log" ] || fail 'no native launch delivery'
assert_contains "$("$ROOT/bin/fm-tasks-axi.sh" show clear)" 'state: in_flight' 'backlog did not start'
pass 'idle watcher retries real spawn and starts queued work beside a parked worker at cap one'
