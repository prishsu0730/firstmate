#!/usr/bin/env bash
# Automatic recovery of an ordinary ship or scout worker whose agent exited
# (bin/fm-worker-liveness-lib.sh driven by bin/fm-watch.sh's
# worker_liveness_tick). Hermetic: a stubbed session provider, a stubbed
# no-mistakes, a real backlog file, and the real fm-control relaunch path.
#   1. An exited agent of an open, In-flight task is relaunched in place, keeps
#      its isolated copy and unlanded commits, and gets a progress note.
#   2. A finished, deliberately stopped, closed, or unproven worker is left
#      alone with no attempt and no notification.
#   3. A worker that keeps dying stops after the bound with one notice.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-worker-liveness) || exit 1
mkdir -p "$TMP_ROOT" || exit 1
TMP_ROOT=$(cd "$TMP_ROOT" && pwd) || exit 1
TASK_TMPS=()

liveness_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_remove_tree "$TMP_ROOT"
}
trap liveness_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control-relaunch.test.sh:
# the harness's exit command stops the agent, and a launch-brief literal starts
# the harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
# A leading `-S <socket>` addresses one exact tmux server. `server` holds
# "<socket>\t<pid>\t<start>" for the single live server (the one a plain call
# reaches too); any other socket has no server, or with `socket-unreadable`
# cannot be read. `windows-sock` is that server's own window inventory.
sock=
if [ "${1:-}" = -S ]; then
  sock=${2:-}; shift 2
  if [ -f "$D/socket-unreadable" ]; then
    echo "error connecting to $sock (Permission denied)" >&2; exit 1
  fi
  if [ ! -f "$D/server" ] || [ "$(cut -f1 "$D/server")" != "$sock" ]; then
    echo "error connecting to $sock (No such file or directory)" >&2; exit 1
  fi
fi
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *start_time*)
          [ -f "$D/server" ] || continue
          case "$a" in
            *socket_path*) cat "$D/server" ;;
            *) cut -f2,3 "$D/server" ;;
          esac
          exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    if [ -n "$sock" ] && [ -f "$D/windows-sock" ]; then cat "$D/windows-sock"; exit 0; fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
}

RUN_ID=01M6WK0RKERRVN0000000000AA

# A no-mistakes stub that answers `axi status` with one active run, so the
# relaunch note can name it.
make_nm_stub() {  # <case-dir>
  cat > "$1/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
branch=\$(git symbolic-ref --quiet --short HEAD)
head=\$(git rev-parse HEAD)
status=\${FM_FAKE_NM_STATUS:-running}
head=\${FM_FAKE_NM_HEAD:-\$head}
if [ "\${1:-} \${2:-}" = "axi status" ]; then
  printf 'run:\n  id: %s\n  branch: %s\n  status: %s\n  head: %s\n' "$RUN_ID" "\${FM_FAKE_NM_STATUS_BRANCH:-\$branch}" "\$status" "\$head"
  exit 0
elif [ "\${1:-}" = axi ]; then
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  %s,%s,%s,%s,\n' "$RUN_ID" "\$branch" "\$status" "\$head"
  exit 0
fi
exit 1
SH
  chmod +x "$1/fakebin/no-mistakes"
}

# new_case <name> -> echoes a case dir whose one ship task's agent has exited.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  make_nm_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [kind]: a real worktree with one landed commit
# and one uncommitted file, its brief, and its record.
add_ship_task() {
  local dir=$1 id=$2 kind=${3:-ship}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  printf 'landed\n' > "$wt/landed.txt"
  git -C "$wt" add landed.txt
  git -C "$wt" commit -qm "unlanded work for $id"
  printf 'in progress\n' > "$wt/uncommitted.txt"
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nKeep working on %s.\n\n## Firstmate spec\nFinish the change.\n' "$id" \
    > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

seed_backlog() {  # <case-dir> <id> <queued|in_flight>
  local file="$1/home/data/backlog.md"
  [ -f "$file" ] || printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$2" "liveness fixture task" --kind ship --file "$file" >/dev/null
  [ "$3" != in_flight ] || tasks-axi start "$2" --file "$file" >/dev/null
}

case_env() {  # <case-dir> <command...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_WORKER_LIVENESS_GRACE_SECS=0 \
    "$@"
}

# run_tick <case-dir>: one watcher worker-liveness tick with delivery captured
# in home/wake-delivered. The cadence marker is cleared afterwards so the next
# call is a fresh tick.
run_tick() {
  local dir=$1 rc=0
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  case_env "$dir" bash -c '. "$1/bin/fm-watch.sh"
    wake() { printf "%s\n" "$1" >> "$FM_HOME/wake-delivered"; }
    worker_liveness_tick' _ "$ROOT" > "$dir/tick.out" 2>&1 || rc=$?
  rm -f "$dir/home/state/.worker-liveness-tick"
  return "$rc"
}

launches() {  # <case-dir>
  grep -c 'Firstmate operational input waiting: read' "$1/fake/literal" || true
}

attempts() {  # <case-dir> <id>
  [ -f "$1/home/state/.worker-relaunch-$2" ] || { echo 0; return; }
  awk -F '\t' '$2 == "attempt"' "$1/home/state/.worker-relaunch-$2" | wc -l | tr -d ' '
}

assert_untouched() {  # <case-dir> <id> <why>
  local dir=$1 id=$2 why=$3
  [ "$(launches "$dir")" = 0 ] || fail "$why: the worker was relaunched"
  [ ! -e "$dir/home/state/.worker-relaunch-$id" ] || fail "$why: an attempt was ledgered: $(cat "$dir/home/state/.worker-relaunch-$id")"
  [ ! -s "$dir/home/wake-delivered" ] || fail "$why: a notification was delivered: $(cat "$dir/home/wake-delivered")"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "$why: the endpoint changed"
}

# --- 1. an exited agent comes back with its work and a progress note ---------

test_exited_agent_is_relaunched_with_work_kept_and_a_progress_note() {
  local dir brief
  dir=$(new_case dead)
  add_ship_task "$dir" wk1
  seed_backlog "$dir" wk1 in_flight
  printf '%s\n' 'working [at=1]: started' "paused [at=2]: waiting on no-mistakes run $RUN_ID" \
    > "$dir/home/state/wk1.status"
  mkdir -p "$dir/home/state/wk1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=3\n--\nPlease also check the docs.\nSecond line.\n' \
    > "$dir/home/state/wk1.inbox/001.msg"

  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"

  [ "$(launches "$dir")" = 1 ] \
    || fail "the exited worker should be relaunched exactly once: $(cat "$dir/tick.out" "$dir/home/wake-delivered" 2>/dev/null)"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the replacement agent should be running"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "an uncommitted file in the isolated copy was lost"
  git -C "$dir/wt" log --format=%s | grep -Fx 'unlanded work for wk1' >/dev/null \
    || fail "an unlanded commit was lost"
  [ "$(grep '^worktree=' "$dir/home/state/wk1.meta" | tail -1 | cut -d= -f2-)" = "$dir/wt" ] \
    || fail "the relaunch must reuse the same isolated copy"
  brief=$(cat "$dir/home/data/wk1/brief.md")
  assert_contains "$brief" "## Progress note" "the brief should carry the relaunch note"
  assert_contains "$brief" "relaunched you automatically" "the note should say why the worker restarted"
  assert_contains "$brief" "paused [at=2]: waiting on no-mistakes run" "the note should carry the last status lines"
  assert_contains "$brief" "No-mistakes run: $RUN_ID (running" "the note should name the active run"
  assert_contains "$brief" "001.msg: Please also check the docs." "the note should list the unread message"
  assert_grep 'check: worker wk1 auto-relaunched after its agent exited' "$dir/home/wake-delivered" \
    "the relaunch should be reported once"
  assert_grep 'worker-relaunch-wk1-' "$dir/home/state/.wake-queue" "the relaunch should leave a durable notification"
  [ "$(attempts "$dir" wk1)" = 1 ] || fail "one attempt should be ledgered"
  grep -q $'\trelaunched$' "$dir/home/state/.worker-relaunch-wk1" || fail "the success should be ledgered"
  ! grep -q $'\tfailed$' "$dir/home/state/.worker-relaunch-wk1" || fail "successful tmux relaunch consumed failure budget"
  ! ls "$dir/home/state"/.worker-relaunch-note-* >/dev/null 2>&1 || fail "the temporary note was left behind"

  : > "$dir/home/wake-delivered"
  run_tick "$dir" || fail "the follow-up tick failed: $(cat "$dir/tick.out")"
  [ "$(launches "$dir")" = 1 ] || fail "a live replacement must not be relaunched again"
  [ ! -s "$dir/home/wake-delivered" ] || fail "a live worker should produce no notification"
  pass "worker liveness: an exited agent is relaunched in place with its work kept and a progress note"
}

test_worker_waiting_on_a_decision_is_still_recovered() {
  local dir
  dir=$(new_case decision)
  add_ship_task "$dir" wk2 scout
  seed_backlog "$dir" wk2 in_flight
  printf '%s\n' 'needs-decision [at=5] [key=k1]: pick a layout' > "$dir/home/state/wk2.status"
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  [ "$(launches "$dir")" = 1 ] \
    || fail "a dead worker waiting on a decision cannot receive the answer and should be relaunched: $(cat "$dir/tick.out")"
  assert_contains "$(cat "$dir/home/data/wk2/brief.md")" "No-mistakes run: $RUN_ID" "the note should be written for a scout too"
  pass "worker liveness: a dead worker that declared a decision wait is still relaunched"
}

# --- 2. finished, stopped, closed, or unproven workers are left alone ---------

test_finished_worker_is_not_relaunched() {
  local dir verb
  for verb in "done" "failed"; do
    dir=$(new_case "$verb")
    add_ship_task "$dir" wk3
    seed_backlog "$dir" wk3 in_flight
    printf '%s\n' 'working [at=1]: started' "$verb [at=2]: finished" > "$dir/home/state/wk3.status"
    run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
    assert_untouched "$dir" wk3 "a worker whose last status is $verb"
  done
  pass "worker liveness: a worker that reported done or failed is never relaunched"
}

test_deliberately_stopped_worker_is_not_relaunched() {
  local dir out rc
  dir=$(new_case stopped)
  add_ship_task "$dir" wk4
  seed_backlog "$dir" wk4 in_flight
  printf 'claude' > "$dir/fake/command"
  out=$(case_env "$dir" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" wk4 exit 2>&1); rc=$?
  expect_code 0 "$rc" "the deliberate exit should succeed"$'\n'"$out"
  [ -f "$dir/home/state/.worker-stopped-wk4" ] || fail "the deliberate exit should leave its stop marker"
  : > "$dir/fake/literal"
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  assert_untouched "$dir" wk4 "a deliberately stopped worker"
  pass "worker liveness: a worker stopped through fm-control exit stays stopped"
}

test_closed_or_unopened_task_is_not_relaunched() {
  local dir
  dir=$(new_case queued)
  add_ship_task "$dir" wk5
  seed_backlog "$dir" wk5 queued
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  assert_untouched "$dir" wk5 "a worker whose item is not In flight"

  dir=$(new_case archived)
  add_ship_task "$dir" wk5
  seed_backlog "$dir" other in_flight
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  assert_untouched "$dir" wk5 "a worker whose item is no longer in the backlog"

  dir=$(new_case closing)
  add_ship_task "$dir" wk5
  seed_backlog "$dir" wk5 in_flight
  : > "$dir/home/state/wk5.backlog-close"
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  assert_untouched "$dir" wk5 "a worker whose close is pending"
  pass "worker liveness: a task that is closed, closing, or not In flight is never relaunched"
}

test_stop_after_probe_releases_recovery_attempt() {
  local dir
  dir=$(new_case stop-race)
  add_ship_task "$dir" wk9 scout
  seed_backlog "$dir" wk9 in_flight
  case_env "$dir" bash -s -- "$ROOT" > "$dir/tick.out" 2>&1 <<'SH' \
    || fail "stop race failed: $(cat "$dir/tick.out")"
    . "$1/bin/fm-watch.sh"
    meta="$STATE/wk9.meta"
    fm_worker_liveness_probe "$meta" wk9
    [ "$FM_WK_LIVE_STATUS" = relaunchable ] || exit 1
    : > "$STATE/.worker-stopped-wk9"
    fm_worker_liveness_relaunch "$meta" wk9 30 && exit 1
    [ "$FM_WK_LIVE_STATUS" = skipped ] || exit 1
    [ "$(fm_worker_liveness_recent_attempts wk9 3600)" = 0 ] || exit 1
    [ -f "$STATE/.worker-stopped-wk9" ] || exit 1
SH
  [ "$(launches "$dir")" = 0 ] || fail "the deliberately stopped scout relaunched"
  ! grep -q $'\tfailed$' "$dir/home/state/.worker-relaunch-wk9" || fail "the refusal counted as failure"
  pass "worker liveness: a stop after probing releases the recovery attempt"
}

test_leased_worker_preserves_recovery_budget_then_relaunches() {
  local dir i FM_SUPERVISION_ACTOR=main
  export FM_SUPERVISION_ACTOR
  dir=$(new_case leased)
  add_ship_task "$dir" wk10
  seed_backlog "$dir" wk10 in_flight
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$dir/home/state/.lease-wk10"
  for i in 1 2 3 4; do
    run_tick "$dir" || fail "leased tick $i failed: $(cat "$dir/tick.out")"
    [ "$(launches "$dir")" = 0 ] || fail "the leased worker was relaunched"
    [ ! -s "$dir/home/wake-delivered" ] || fail "lease contention raised a notice"
    [ ! -s "$dir/home/state/.wake-queue" ] || fail "lease contention queued a notice"
    [ ! -e "$dir/home/state/.worker-relaunch-bound-wk10" ] || fail "lease contention parked recovery"
    [ "$(grep -c $'\treleased$' "$dir/home/state/.worker-relaunch-wk10")" = "$i" ] || fail "the lease refusal was not released"
    ! grep -q $'\tfailed$' "$dir/home/state/.worker-relaunch-wk10" || fail "lease contention counted as failure"
    # shellcheck disable=SC2016 # Expanded by the inner shell.
    case_env "$dir" bash -c '. "$1/bin/fm-watch.sh"; [ "$(fm_worker_liveness_recent_attempts wk10 3600)" = 0 ]' _ "$ROOT" \
      || fail "lease contention consumed the retry budget"
  done
  [ -f "$dir/home/state/.lease-wk10" ] || fail "recovery removed the other actor's lease"
  rm -f "$dir/home/state/.lease-wk10"
  run_tick "$dir" || fail "the released tick failed: $(cat "$dir/tick.out")"
  [ "$(launches "$dir")" = 1 ] || fail "the worker did not relaunch after the lease cleared"
  assert_grep 'check: worker wk10 auto-relaunched' "$dir/home/wake-delivered" "recovery should resume after contention"
  pass "worker liveness: lease contention preserves recovery budget until the lease clears"
}

test_ineligible_worker_does_not_starve_later_worker() {
  local dir
  dir=$(new_case starvation)
  add_ship_task "$dir" wk8
  seed_backlog "$dir" wk8 in_flight
  cat "$dir/home/state/wk8.meta" > "$dir/home/state/aa.meta"
  printf '%s\n' fm-aa >> "$dir/fake/windows"
  seed_backlog "$dir" aa queued
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  [ "$(launches "$dir")" = 1 ] || fail "the later eligible worker was starved"
  [ "$(attempts "$dir" aa)" = 0 ] || fail "the queued worker recorded an attempt"
  [ "$(attempts "$dir" wk8)" = 1 ] || fail "the eligible worker was not attempted"
  pass "worker liveness: an earlier queued worker leaves recovery available"
}

test_blocked_worker_preserves_recovery_budget_and_tick_slot() {
  local dir
  dir=$(new_case blocked)
  add_ship_task "$dir" wk8
  seed_backlog "$dir" wk8 in_flight
  seed_backlog "$dir" blocker queued
  tasks-axi block wk8 --by blocker --file "$dir/home/data/backlog.md" >/dev/null
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  assert_untouched "$dir" wk8 "a blocked In-flight worker"

  cat "$dir/home/state/wk8.meta" > "$dir/home/state/aa.meta"
  printf '%s\n' fm-aa >> "$dir/fake/windows"
  seed_backlog "$dir" aa in_flight
  tasks-axi block aa --by blocker --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi unblock wk8 --by blocker --file "$dir/home/data/backlog.md" >/dev/null
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  [ "$(launches "$dir")" = 1 ] || fail "the later unblocked worker was starved"
  [ ! -e "$dir/home/state/.worker-relaunch-aa" ] || fail "the blocked worker recorded an attempt"
  [ "$(attempts "$dir" wk8)" = 1 ] || fail "the unblocked worker was not attempted"
  [ "$(wc -l < "$dir/home/wake-delivered" | tr -d ' ')" = 1 ] || fail "expected only the unblocked worker's notice"
  pass "worker liveness: blocked workers preserve recovery budget and the tick slot"
}

test_unproven_endpoint_absence_is_not_relaunched() {
  local dir
  dir=$(new_case unproven)
  add_ship_task "$dir" wk6
  seed_backlog "$dir" wk6 in_flight
  : > "$dir/fake/windows"
  run_tick "$dir" || fail "the tick failed: $(cat "$dir/tick.out")"
  [ "$(launches "$dir")" = 0 ] || fail "unproven worker relaunched"
  [ "$(attempts "$dir" wk6)" = 0 ] || fail "unproven worker consumed retry budget"
  run_tick "$dir" || fail "second tick failed"
  [ "$(wc -l < "$dir/home/wake-delivered" | tr -d ' ')" = 1 ] || fail "missing worker must notify exactly once"
  pass "worker liveness: a missing endpoint without absence proof is left for a person"
}

# --- 3. a worker that keeps dying stops after the bound ---------------------

test_repeated_death_parks_after_the_bound_then_rearms() {
  local dir i delivered
  dir=$(new_case flapping)
  add_ship_task "$dir" wk7
  seed_backlog "$dir" wk7 in_flight
  printf 'zsh' > "$dir/fake/becomes"
  for i in 1 2 3; do
    run_tick "$dir" || fail "tick $i failed: $(cat "$dir/tick.out")"
    [ "$(attempts "$dir" wk7)" = "$i" ] || fail "tick $i should ledger attempt $i, got $(attempts "$dir" wk7)"
  done
  [ "$(grep -c 'check: worker wk7 auto-relaunch failed' "$dir/home/wake-delivered")" = 3 ] \
    || fail "each failed relaunch should be reported: $(cat "$dir/home/wake-delivered")"

  run_tick "$dir" || fail "the bound tick failed: $(cat "$dir/tick.out")"
  [ "$(attempts "$dir" wk7)" = 3 ] || fail "the bound must stop further attempts"
  [ -f "$dir/home/state/.worker-relaunch-bound-wk7" ] || fail "the bound should park the worker"
  [ "$(grep -c 'worker-relaunch-bound-wk7' "$dir/home/state/.wake-queue")" = 1 ] \
    || fail "the bound should raise exactly one notice"
  assert_grep 'check: worker wk7 auto-relaunch paused after 3 attempts' "$dir/home/wake-delivered" \
    "the notice should say the automatic relaunch stopped"

  delivered=$(wc -l < "$dir/home/wake-delivered")
  run_tick "$dir" || fail "the parked tick failed: $(cat "$dir/tick.out")"
  [ "$(attempts "$dir" wk7)" = 3 ] || fail "a parked worker must not be retried"
  [ "$(wc -l < "$dir/home/wake-delivered")" = "$delivered" ] || fail "a parked worker must stay silent"
  [ "$(grep -c 'worker-relaunch-bound-wk7' "$dir/home/state/.wake-queue")" = 1 ] \
    || fail "a parked worker must not raise a second notice"

  printf 'claude' > "$dir/fake/command"
  run_tick "$dir" || fail "the rearm tick failed: $(cat "$dir/tick.out")"
  [ ! -e "$dir/home/state/.worker-relaunch-bound-wk7" ] || fail "a live probe should clear the park"
  grep -q $'\trearmed$' "$dir/home/state/.worker-relaunch-wk7" || fail "the rearm should be ledgered"
  pass "worker liveness: a worker that keeps dying stops after the bound with one notice, then rearms when live"
}

test_other_branch_run_is_not_named() {
  local dir brief
  dir=$(new_case other-branch)
  add_ship_task "$dir" wk-other
  seed_backlog "$dir" wk-other in_flight
  printf 'working: prior run %s\n' "$RUN_ID" > "$dir/home/state/wk-other.status"
  FM_FAKE_NM_STATUS_BRANCH=task-someone-else run_tick "$dir" || fail "tick failed"
  brief=$(cat "$dir/home/data/wk-other/brief.md")
  assert_contains "$brief" "No-mistakes run: unknown." "mismatched run must remain unknown"
  assert_contains "$brief" "branch task-wk-other" "unknown run guidance must name this branch"
  [[ "$brief" != *"No-mistakes run: $RUN_ID"* ]] || fail "another branch run was attributed to this worker"
  [ "$(launches "$dir")" = 1 ] || fail "worker should still restart"
  pass "worker liveness: another branch run is not attributed to the worker"
}

test_stale_failed_run_is_not_named() {
  local dir brief
  dir=$(new_case stale-run)
  add_ship_task "$dir" wk-stale
  seed_backlog "$dir" wk-stale in_flight
  FM_FAKE_NM_STATUS=failed FM_FAKE_NM_HEAD=$(git -C "$dir/wt" rev-parse HEAD^) \
    run_tick "$dir" || fail "tick failed"
  brief=$(cat "$dir/home/data/wk-stale/brief.md")
  assert_contains "$brief" "No-mistakes run: unknown." "stale failed run must remain unknown"
  assert_contains "$brief" "branch task-wk-stale" "unknown run guidance must name this branch"
  [[ "$brief" != *"$RUN_ID"* ]] || fail "stale failed run was named in the note"
  [ "$(launches "$dir")" = 1 ] || fail "worker should still restart"
  pass "worker liveness: a failed run behind the worker HEAD is not named"
}

test_generic_parked_worker_rearms_after_manual_relaunch() {
  local dir gen i
  dir=$(new_case generic-rearm)
  add_ship_task "$dir" wk-generic
  seed_backlog "$dir" wk-generic in_flight
  printf 'spawn_gen=old\n' >> "$dir/home/state/wk-generic.meta"
  printf 'old\n' > "$dir/home/state/.worker-exit-wk-generic"
  printf '1\tdead\n' > "$dir/home/state/.worker-relaunch-bound-wk-generic"
  for i in 1 2 3; do
    printf '%s\tattempt\n' "$(date +%s)" >> "$dir/home/state/.worker-relaunch-wk-generic"
  done
  cat > "$dir/generic-env.sh" <<SH
. '$ROOT/bin/fm-backend.sh'
fm_backend_source tmux
unset -f fm_backend_tmux_agent_state
SH
  BASH_ENV="$dir/generic-env.sh" run_tick "$dir" || fail "parked generic tick failed"
  [ "$(launches "$dir")" = 0 ] || fail "parked generic worker restarted"
  BASH_ENV="$dir/generic-env.sh" case_env "$dir" "$ROOT/bin/fm-control.sh" wk-generic relaunch --note 'Resume work' \
    > "$dir/manual.out" 2>&1 || fail "manual generic relaunch failed: $(cat "$dir/manual.out")"
  [ ! -e "$dir/home/state/.worker-relaunch-bound-wk-generic" ] || fail "manual launch left retry pause"
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  BASH_ENV="$dir/generic-env.sh" case_env "$dir" bash -c '
    . "$1/bin/fm-worker-liveness-lib.sh"
    STATE=$FM_HOME/state
    [ "$(fm_worker_liveness_recent_attempts wk-generic 3600)" = 0 ]
    [ "$(fm_backend_agent_state tmux fmses:fm-wk-generic)" = ambiguous ]
  ' _ "$ROOT" || fail "manual launch did not reset budget while preserving ambiguous"
  gen=$(sed -n 's/^spawn_gen=//p' "$dir/home/state/wk-generic.meta")
  printf '%s\n' "$gen" > "$dir/home/state/.worker-exit-wk-generic"
  BASH_ENV="$dir/generic-env.sh" run_tick "$dir" || fail "later proven exit tick failed"
  [ "$(launches "$dir")" = 2 ] || fail "later proven exit was not automatically recovered"
  pass "generic classifier worker rearms after manual relaunch and recovers a later exit"
}

test_generic_parked_worker_rearms_after_manual_relaunch
test_stale_failed_run_is_not_named
test_other_branch_run_is_not_named
test_exited_agent_is_relaunched_with_work_kept_and_a_progress_note
test_worker_waiting_on_a_decision_is_still_recovered
test_finished_worker_is_not_relaunched
test_deliberately_stopped_worker_is_not_relaunched
test_closed_or_unopened_task_is_not_relaunched
test_stop_after_probe_releases_recovery_attempt
test_leased_worker_preserves_recovery_budget_then_relaunches
test_ineligible_worker_does_not_starve_later_worker
test_blocked_worker_preserves_recovery_budget_and_tick_slot
test_unproven_endpoint_absence_is_not_relaunched
test_repeated_death_parks_after_the_bound_then_rearms
