#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { printf "%s\n" "$*" >&2; exit 1; }
pass() { printf "ok - %s\n" "$*"; }
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
mkdir -p "$FM_STATE_OVERRIDE" "$TMP_ROOT/mate/state" "$TMP_ROOT/project"
. "$ROOT/bin/fm-watch.sh"
fm_local_firstmate_state_dirs() {
  FM_LOCAL_FIRSTMATE_STATES=("$STATE" "$TMP_ROOT/mate/state")
}
fm_treehouse_project_lock_path() { printf '%s/project-lock\n' "$TMP_ROOT"; }
FM_TASKS_AXI_BIN="$TMP_ROOT/tasks"
printf '#!/usr/bin/env bash\nprintf "ready[2]\\n"\n' > "$FM_TASKS_AXI_BIN"
chmod +x "$FM_TASKS_AXI_BIN"
printf 'kind=ship\nproject=%s\n' "$TMP_ROOT/project" > "$TMP_ROOT/mate/state/worker.meta"
expect_signal() {
  local rc=0
  ready_queue_signal || rc=$?
  [ "$rc" = "$1" ] || fail "expected queue result $1, got $rc"
}
expect_signal 2
expect_signal 0
printf 'pr=123\n' >> "$TMP_ROOT/mate/state/worker.meta"
expect_signal 2
expect_signal 0
printf 'kind=scout\nproject=%s\n' "$TMP_ROOT/project" > "$TMP_ROOT/mate/state/scout.meta"
expect_signal 2
mv "$TMP_ROOT/mate/state/scout.meta" "$TMP_ROOT/scout-record"
expect_signal 2
expect_signal 0
PAUSE_RESURFACE_SECS=14400
PAUSE_SAFETY_RECHECK_SECS=86400
FM_MAIN_WAIT_SECS=3600
printf 'declared:test' > "$STATE/.paused-resurfaced-pane"
touch -t 202001010000 "$STATE/.paused-resurfaced-pane"
stale_wait_throttled pane declared:test 'paused: waiting for external CI' && fail 'expired safety check suppressed'
touch "$STATE/.paused-resurfaced-pane"
stale_wait_throttled pane declared:test 'paused: waiting for external CI' || fail 'fresh external wait repeated'
[ "$(watch_pause_recheck_secs 'paused: waiting for external CI')" = 86400 ] || fail 'external wait cadence'
[ "$(watch_pause_recheck_secs 'paused: waiting on firstmate')" = 3600 ] || fail 'firstmate wait cadence'
[ "$(watch_pause_recheck_secs '')" = 14400 ] || fail 'ordinary cadence'
pass 'queue capacity releases and shared wait cadence'
