#!/usr/bin/env bash
# Full queue -> fm-spawn -> task metadata/backlog/launch delivery regression.
# The backend and agent are fixture executables; all lifecycle scripts are real.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue-spawn)
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
"$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" parked --state idle --source claude-hook --event stop >/dev/null || fail 'parked hook'
printf 'paused [at=%s]: waiting for an external condition\n' "$(date +%s)" > "$FM_HOME/state/parked.status"
"$ROOT/bin/fm-tasks-axi.sh" add clear 'queued integration task' >/dev/null || fail 'queued row'
fm_test_spawn_brief "$FM_HOME" clear
"$ROOT/bin/fm-queue-pull.sh" prepare clear "$TMP_ROOT/project" --mode no-mistakes --yolo off --harness codex || fail 'prepare'
"$ROOT/bin/fm-queue-pull.sh" tick || fail 'tick'
report=$(cat "$FM_HOME/state/.queue-pull-report")
assert_contains "$report" 'clear: started through fm-spawn' 'queue did not launch through real spawn'
[ -f "$FM_HOME/state/clear.meta" ] || fail 'spawn metadata missing'
[ -s "$TMP_ROOT/launch.log" ] || fail 'no native launch delivery'
assert_contains "$("$ROOT/bin/fm-tasks-axi.sh" show clear)" 'state: in_flight' 'backlog did not start'
pass 'real spawn starts a clear queued item with a live parked worker at away cap one'
