#!/usr/bin/env bash
# tests/fm-session-lock-foreign-holder.test.sh - a lock holder counts as the
# home's own session only when Firstmate launched it into the home's recorded
# endpoint (bin/fm-lock.sh, bin/fm-session-lock-lib.sh).
#
# Real processes throughout: harness-named bash symlinks stand in for the real
# session (claude) and for the Codex desktop app's shared app-server daemon
# (codex), a bash fixture stands in for the tmux pane process, and a fake tmux
# answers `list-panes` with the pane pid the parent's launch record points at.
# The cases pin the three holder verdicts the foreign-holder check must keep
# apart: the launched session (live, generic refusal, unchanged), a harness-shaped
# process outside the endpoint (foreign: loud refusal, one parent alarm, no
# steal), and a dead holder (stale, reclaimed, unchanged).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-foreign-holder)
LIB="$ROOT/bin/fm-session-lock-lib.sh"
LOCK="$ROOT/bin/fm-lock.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
ln -s /bin/bash "$FAKEBIN/codex"
NAMED_CLAUDE="$FAKEBIN/claude"
NAMED_CODEX="$FAKEBIN/codex"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes)
    [ -n "${FM_TEST_PANE_PIDS:-}" ] || exit 1
    printf '%s\n' $FM_TEST_PANE_PIDS
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

FIXTURE_PIDS=()
reap_fixtures() {
  local pid
  for pid in ${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_fixtures; fm_test_cleanup' EXIT

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "fixture never produced $2"
}

# Start <binary> running a bounded idle loop in the background, recording its
# own pid in <pidfile>. A child of the test shell, so it is not under any pane.
start_idle() {  # <binary> <pidfile>
  "$1" -c 'printf "%s\n" "$$" > "$0"; while [ "$SECONDS" -lt 120 ]; do sleep 1; done' "$2" &
  FIXTURE_PIDS+=("$!")
  wait_for_file "$2" "the idle process $2"
  FIXTURE_PIDS+=("$(tr -d '[:space:]' < "$2")")
}

# Start a pane stand-in that records its pid and runs <holder-binary> as its own
# child, the shape a harness launched into a tmux pane has.
start_pane_with_holder() {  # <dir> <holder-binary>
  local dir=$1
  cat > "$dir/pane.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$1/pane-pid"
"$2" -c 'printf "%s\n" "$$" > "$0/holder-pid"; while [ "$SECONDS" -lt 120 ]; do sleep 1; done' "$1" &
wait
SH
  chmod +x "$dir/pane.sh"
  "$dir/pane.sh" "$dir" "$2" &
  FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/pane-pid" "the pane pid"
  wait_for_file "$dir/holder-pid" "the pane's harness pid"
  FIXTURE_PIDS+=("$(tr -d '[:space:]' < "$dir/holder-pid")")
}

# A parent home with the mate's launch record, and a seeded mate home bound to it.
make_mate_home() {  # <dir> -> prints the mate home
  local dir=$1
  mkdir -p "$dir/parent/state" "$dir/mate/state"
  printf 'mate1\n' > "$dir/mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" \
    > "$dir/mate/.fm-secondmate-parent"
  printf 'window=firstmate:fm-mate1\nendpoint_task_id=mate1\nkind=secondmate\nmode=secondmate\nharness=claude\nhome=%s\nworktree=%s\n' \
    "$dir/mate" "$dir/mate" > "$dir/parent/state/mate1.meta"
  printf '%s\n' "$dir/mate"
}

# Run fm-lock.sh [status] as a new Claude-named session in <home>, with the fake
# tmux answering <pane-pids>. Output and exit code land in <home>/state/run.*.
run_lock() {  # <home> <pane-pids> [status]
  local home=$1 panes=$2 sub=${3:-}
  rm -f "$home/state/run.out" "$home/state/run.rc"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$home" FM_LOCK="$LOCK" FM_TEST_PANE_PIDS="$panes" PATH="$FAKEBIN:$PATH" \
    "$NAMED_CLAUDE" -c '"$FM_LOCK" ${1:+"$1"} > "$FM_HOME/state/run.out" 2>&1; printf "%s\n" "$?" > "$FM_HOME/state/run.rc"' _ "$sub"
  RUN_OUT=$(cat "$home/state/run.out")
  RUN_RC=$(tr -d '[:space:]' < "$home/state/run.rc")
}

# Run one library expression as a separate bash with the real ps.
lib_eval() {  # <expression>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$FAKEBIN:$PATH" \
    bash -c '. "$0"; '"$1" "$LIB"
}

parent_status_lines() {  # <dir>
  if [ -f "$1/parent/state/mate1.status" ]; then
    grep -c . "$1/parent/state/mate1.status" || true
  else
    echo 0
  fi
}

test_launched_holder_is_live_and_refusal_is_unchanged() {
  local dir home pane holder
  dir="$TMP_ROOT/launched"
  mkdir -p "$dir"
  home=$(make_mate_home "$dir")
  start_pane_with_holder "$dir" "$NAMED_CLAUDE"
  pane=$(tr -d '[:space:]' < "$dir/pane-pid")
  holder=$(tr -d '[:space:]' < "$dir/holder-pid")
  printf '%s\n' "$holder" > "$home/state/.lock"

  lib_eval "fm_session_lock_pid_descends_from $holder $pane" \
    || fail "the launched session did not descend from its pane (the foreign case would be vacuous)"
  run_lock "$home" "$pane"
  expect_code 1 "$RUN_RC" "a second session took the launched session's lock"
  assert_contains "$RUN_OUT" "another live firstmate session holds the lock (pid $holder)" \
    "the launched holder lost the unchanged live-owner refusal"
  assert_not_contains "$RUN_OUT" "foreign" "the launched session was called a foreign holder"
  [ "$(parent_status_lines "$dir")" = 0 ] || fail "the launched session raised a parent alarm"
  run_lock "$home" "$pane" status
  assert_contains "$RUN_OUT" "lock: held by live harness pid $holder" "status changed for the launched session"
  assert_not_contains "$RUN_OUT" "FOREIGN" "status called the launched session foreign"
  [ "$(tr -d '[:space:]' < "$home/state/.lock")" = "$holder" ] || fail "the launched session's lock was rewritten"
  pass "foreign-holder: the session launched into the recorded endpoint stays live with the unchanged refusal"
}

test_foreign_daemon_in_the_home_is_refused_loudly_once() {
  local dir home pane daemon before
  dir="$TMP_ROOT/foreign"
  mkdir -p "$dir"
  home=$(make_mate_home "$dir")
  start_idle "$NAMED_CLAUDE" "$dir/pane-pid"
  pane=$(tr -d '[:space:]' < "$dir/pane-pid")
  start_idle "$NAMED_CODEX" "$dir/daemon-pid"
  daemon=$(tr -d '[:space:]' < "$dir/daemon-pid")
  printf '%s\n' "$daemon" > "$home/state/.lock"
  before=$(cat "$home/state/.lock")

  if lib_eval "fm_session_lock_pid_descends_from $daemon $pane"; then
    fail "the daemon descends from the recorded pane, so the foreign case is vacuous"
  fi
  run_lock "$home" "$pane"
  expect_code 1 "$RUN_RC" "a foreign holder did not refuse the new session"
  assert_contains "$RUN_OUT" "held by a foreign process, not the session Firstmate launched for this home (pid $daemon" \
    "the refusal does not name the foreign holder's pid"
  assert_contains "$RUN_OUT" "codex" "the refusal does not name the foreign holder's command"
  assert_contains "$RUN_OUT" "Next step:" "the refusal gives no next step"
  assert_contains "$RUN_OUT" "Firstmate never stops it for you" "the refusal does not say nothing was killed"
  assert_not_contains "$RUN_OUT" "lock acquired" "the foreign holder's lock was stolen"
  [ "$(cat "$home/state/.lock")" = "$before" ] || fail "the foreign holder's lock bytes changed"
  kill -0 "$daemon" 2>/dev/null || fail "the foreign holder was killed"

  [ "$(parent_status_lines "$dir")" = 1 ] || fail "expected one parent alarm, got $(parent_status_lines "$dir")"
  assert_grep "blocked [key=lock-foreign-holder-$daemon] [at=" "$dir/parent/state/mate1.status" \
    "the parent alarm is not a keyed, stamped blocked line"
  assert_grep "pid $daemon" "$dir/parent/state/mate1.status" "the parent alarm does not name the holder"
  run_lock "$home" "$pane"
  expect_code 1 "$RUN_RC" "the second attempt stole the foreign holder's lock"
  [ "$(parent_status_lines "$dir")" = 1 ] || fail "a repeat refusal raised a second parent alarm"

  run_lock "$home" "$pane" status
  assert_contains "$RUN_OUT" "lock: held by FOREIGN harness pid $daemon" "status does not report the foreign holder"
  pass "foreign-holder: a harness-shaped daemon outside the endpoint is refused with pid, command, next step, and one parent alarm"
}

test_dead_holder_is_stale_and_reclaimed() {
  local dir home pane dead
  dir="$TMP_ROOT/dead"
  mkdir -p "$dir"
  home=$(make_mate_home "$dir")
  start_idle "$NAMED_CLAUDE" "$dir/pane-pid"
  pane=$(tr -d '[:space:]' < "$dir/pane-pid")
  "$NAMED_CODEX" -c 'exit 0' &
  dead=$!
  wait "$dead" || true
  printf '%s\n' "$dead" > "$home/state/.lock"

  run_lock "$home" "$pane" status
  assert_contains "$RUN_OUT" "lock: stale (pid $dead dead or not a harness)" "a dead holder is not stale"
  run_lock "$home" "$pane"
  expect_code 0 "$RUN_RC" "a dead holder's lock was not reclaimed: $RUN_OUT"
  assert_contains "$RUN_OUT" "lock acquired: harness pid" "the stale lock was not reclaimed"
  assert_not_contains "$RUN_OUT" "foreign" "a dead holder was called foreign"
  [ "$(parent_status_lines "$dir")" = 0 ] || fail "a dead holder raised a parent alarm"
  pass "foreign-holder: a dead holder stays stale and is reclaimed"
}

# No launch evidence is no verdict: a primary home, an endpoint tmux cannot
# resolve, and a non-tmux endpoint all keep today's generic live-owner refusal.
test_unresolvable_endpoint_keeps_the_generic_refusal() {
  local dir home daemon
  dir="$TMP_ROOT/unknown"
  mkdir -p "$dir"
  start_idle "$NAMED_CODEX" "$dir/daemon-pid"
  daemon=$(tr -d '[:space:]' < "$dir/daemon-pid")

  home=$(make_mate_home "$dir/gone")
  printf '%s\n' "$daemon" > "$home/state/.lock"
  run_lock "$home" ""
  expect_code 1 "$RUN_RC" "a live holder was reclaimed when its window could not be resolved"
  assert_contains "$RUN_OUT" "another live firstmate session holds the lock (pid $daemon)" "unresolvable window changed the refusal"
  assert_not_contains "$RUN_OUT" "foreign" "an unresolvable window was called a foreign holder"
  [ "$(parent_status_lines "$dir/gone")" = 0 ] || fail "an unresolvable window raised a parent alarm"

  home=$(make_mate_home "$dir/herdr")
  printf 'backend=herdr\n' >> "$dir/herdr/parent/state/mate1.meta"
  printf '%s\n' "$daemon" > "$home/state/.lock"
  run_lock "$home" "$$"
  expect_code 1 "$RUN_RC" "a live holder was reclaimed on a non-tmux endpoint"
  assert_not_contains "$RUN_OUT" "foreign" "a non-tmux endpoint was called a foreign holder"

  mkdir -p "$dir/primary/state"
  printf '%s\n' "$daemon" > "$dir/primary/state/.lock"
  run_lock "$dir/primary" "$$"
  expect_code 1 "$RUN_RC" "a primary home reclaimed a live holder"
  assert_contains "$RUN_OUT" "another live firstmate session holds the lock (pid $daemon)" "a primary home changed the refusal"
  assert_not_contains "$RUN_OUT" "foreign" "a primary home was called a foreign holder"
  pass "foreign-holder: with no resolvable launch endpoint the generic live-owner refusal stands"
}

test_holder_verdict_helper() {
  local dir pane child
  dir="$TMP_ROOT/verdict"
  mkdir -p "$dir"
  start_pane_with_holder "$dir" "$NAMED_CLAUDE"
  pane=$(tr -d '[:space:]' < "$dir/pane-pid")
  child=$(tr -d '[:space:]' < "$dir/holder-pid")
  lib_eval "fm_session_lock_holder_launched $child '$pane'" || fail "a pane child was not launched"
  lib_eval "fm_session_lock_holder_launched $pane '$pane'" || fail "the pane process itself was not launched"
  lib_eval "fm_session_lock_holder_launched $child '999999 $pane'" || fail "one matching pane of several was not launched"
  lib_eval "fm_session_lock_holder_launched $child '999999'" && fail "a holder outside every pane was launched"
  lib_eval "fm_session_lock_holder_launched $child '999999'; [ \$? -eq 1 ]" || fail "a holder outside the endpoint was not the foreign verdict"
  lib_eval "fm_session_lock_holder_launched $child ''; [ \$? -eq 2 ]" || fail "no endpoint was not the no-evidence verdict"
  lib_eval "fm_session_lock_holder_launched $child 'junk'; [ \$? -eq 2 ]" || fail "a malformed endpoint was not the no-evidence verdict"
  pass "foreign-holder: the verdict helper separates launched, foreign, and no-evidence"
}

test_launched_holder_is_live_and_refusal_is_unchanged
test_foreign_daemon_in_the_home_is_refused_loudly_once
test_dead_holder_is_stale_and_reclaimed
test_unresolvable_endpoint_keeps_the_generic_refusal
test_holder_verdict_helper
