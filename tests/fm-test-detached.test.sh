#!/usr/bin/env bash
# tests/fm-test-detached.test.sh - contract test for bin/fm-test-detached.sh,
# the detached, resumable wrapper around bin/fm-test-run.sh.
#
# It drives the real wrapper and the real runner over a tiny fake test list in a
# fixture repository, never the Firstmate suite. Every tmux call here goes to a
# private socket (`-L`) inside a private TMUX_TMPDIR, so the host's real tmux
# server is never addressed; the test proves that by asserting the wrapper
# creates no `default` socket there. Nothing in this file stops a whole server:
# the private server exits by itself when its last session ends.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

DETACHED="$ROOT/bin/fm-test-detached.sh"
assert_present "$DETACHED" "bin/fm-test-detached.sh is missing"
[ -x "$DETACHED" ] || fail "bin/fm-test-detached.sh must be executable"

# A short path keeps the tmux socket under the unix-socket length limit.
SOCK_DIR=$(mktemp -d /tmp/fmtd.XXXXXX) || fail "cannot create the private tmux directory"
export TMUX_TMPDIR="$SOCK_DIR"
SOCK="fmtest-detached-$$"
export FM_TEST_DETACHED_SOCKET="$SOCK"

ptm() { env -u TMUX -u TMUX_PANE tmux -L "$SOCK" "$@"; }

FIXTURE=$(fm_test_tmproot fm-test-detached)
REPO="$FIXTURE/repo"
MARK="$FIXTURE/mark"
STATE="$FIXTURE/state"
export FM_STATE_OVERRIDE="$STATE"

cleanup_all() {
  # Let any stand-in script that outlived its session finish, then end only the
  # sessions on this test's private socket; the server leaves with the last one.
  : >"$MARK/gate" 2>/dev/null || true
  local s
  for s in $(ptm list-sessions -F '#{session_name}' 2>/dev/null); do
    ptm kill-session -t "=$s" >/dev/null 2>&1 || true
  done
  rm -rf "$SOCK_DIR"
  fm_test_cleanup
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

wait_for() { # <seconds> <command...>
  local limit=$(($1 * 5)) i=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le "$limit" ] || return 1
    sleep 0.2
  done
}

run_count() { # <marker file> -> lines (0 when absent)
  if [ -f "$1" ]; then awk 'END { print NR }' "$1"; else echo 0; fi
}

session_name() {
  printf 'fm-test-%s\n' "$(printf '%s/%s' "$(cd "$STATE/test-runs" && pwd -P)" "$1" | git hash-object --stdin)"
}
session_gone() { ! ptm has-session -t "=$(session_name "$1")" 2>/dev/null; }
has_line() { grep -q -- "$2" "$1/results.log" 2>/dev/null; }

build_fixture() {
  fm_git_init_commit "$REPO"
  mkdir -p "$REPO/bin" "$REPO/tests" "$MARK"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-test-detached.sh" "$REPO/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$REPO/tests/"
  chmod +x "$REPO/bin/fm-test-run.sh" "$REPO/bin/fm-test-detached.sh"
  # a passes and records what the worker's environment looked like; b waits for a
  # gate file so the test can cut the run off while b is in flight; c fails.
  cat >"$REPO/tests/a.test.sh" <<EOF
#!/usr/bin/env bash
echo a >>"$MARK/a.runs"
echo "probe=\${FM_DETACHED_PROBE-unset} tmux=\${TMUX-unset}" >"$MARK/a.env"
echo "ok - a"
EOF
  cat >"$REPO/tests/b.test.sh" <<EOF
#!/usr/bin/env bash
echo b >>"$MARK/b.runs"
while [ ! -e "$MARK/gate" ]; do sleep 0.1; done
echo "ok - b"
EOF
  cat >"$REPO/tests/c.test.sh" <<EOF
#!/usr/bin/env bash
echo c >>"$MARK/c.runs"
echo "not ok - c"
exit 3
EOF
  cat >"$REPO/tests/d.test.sh" <<EOF
#!/usr/bin/env bash
while [ ! -e "$MARK/gate" ]; do sleep 0.1; done
echo "ok - d"
EOF
  chmod +x "$REPO"/tests/*.test.sh
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qm fixture
}

SEL=(tests/a.test.sh tests/b.test.sh tests/c.test.sh)
RUNNAME=resume
RUNDIR="$STATE/test-runs/$RUNNAME"
start() { # [extra wrapper args...]; prints the wrapper's output
  (cd "$REPO" && FM_DETACHED_PROBE=hello TMUX=/nonexistent/sock,1,0 \
    "$REPO/bin/fm-test-detached.sh" --name "$RUNNAME" "$@" "${SEL[@]}")
}

build_fixture

test_runs_detached_on_a_private_socket() {
  local out rc
  out=$(start 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "first start"
  assert_contains "$out" "results=$RUNDIR" "start must print where the results live"
  assert_contains "$out" "private socket $SOCK" "start must name the private socket"
  assert_contains "$out" "0 of 3 scripts already finished" "a fresh run has nothing finished"
  # The wrapper returned while the run is still live: a is done, b is gated.
  wait_for 30 has_line "$RUNDIR" 'tests/a.test.sh' || fail "script a never recorded a result"
  wait_for 30 test -f "$MARK/b.runs" || fail "script b never started"
  ptm has-session -t "=$(session_name "$RUNNAME")" || fail "the run must live in a session on the private server"
  [ -S "$SOCK_DIR/tmux-$(id -u)/$SOCK" ] || fail "the private socket is missing under TMUX_TMPDIR"
  [ -z "$(find "$SOCK_DIR" -name default)" ] || fail "the wrapper created or used a default tmux server"
  out=$("$REPO/bin/fm-test-detached.sh" --status "$RUNNAME" 2>&1)
  assert_contains "$out" "state=running finished=1/3" "status must show a live run"
  assert_contains "$out" "running: tests/b.test.sh" "status must name the script in flight"
  pass "the run is detached, on a private socket, and reports where results live"
}

test_worker_environment() {
  local env_seen
  env_seen=$(cat "$MARK/a.env")
  assert_equals "probe=hello tmux=unset" "$env_seen" \
    "the worker must get the caller's environment but never an inherited TMUX"
  pass "the worker keeps the caller's environment and drops TMUX"
}

test_cut_off_run_resumes_without_rerunning_finished_files() {
  local out rc
  # Simulate the restart: end the session while b is in flight.
  ptm kill-session -t "=$(session_name "$RUNNAME")" || fail "could not end the run's session"
  wait_for 30 session_gone "$RUNNAME" || fail "the session did not end"
  out=$("$REPO/bin/fm-test-detached.sh" --status "$RUNNAME" 2>&1)
  assert_contains "$out" "state=stopped finished=1/3" "a cut-off run must read as stopped"
  : >"$MARK/gate"
  out=$(start 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "resume start"
  assert_contains "$out" "1 of 3 scripts already finished" "resume must see a as finished"
  wait_for 60 has_line "$RUNDIR" '^COMPLETE ' || fail "the resumed run never completed"
  assert_equals 1 "$(run_count "$MARK/a.runs")" "a was already finished and must not run again"
  assert_equals 2 "$(run_count "$MARK/b.runs")" "b was cut off and must run again"
  assert_equals 1 "$(run_count "$MARK/c.runs")" "c runs once"
  assert_equals 3 "$(grep -c '^FINISHED ' "$RUNDIR/results.log")" "one FINISHED line per script"
  has_line "$RUNDIR" 'FINISHED exit=0 at=[0-9]* tests/b.test.sh' || fail "b should finish after the gate opens"
  has_line "$RUNDIR" 'FINISHED exit=[1-9][0-9]* at=[0-9]* tests/c.test.sh' || fail "c's failure must be recorded with a non-zero exit"
  has_line "$RUNDIR" '^COMPLETE total=3 failed=1 ' || fail "the run summary must count the failure"
  assert_present "$RUNDIR/out/tests_c.test.sh.log" "each script's full output must be kept"
  assert_grep "not ok - c" "$RUNDIR/out/tests_c.test.sh.log" "c's output must be in its log"
  out=$("$REPO/bin/fm-test-detached.sh" --status "$RUNNAME" 2>&1)
  assert_contains "$out" "state=complete finished=3/3 failed=1" "status must show the finished run"
  assert_contains "$out" "failed: tests/c.test.sh" "status must name the failing script"
  pass "a cut-off run resumes, skipping finished files and rerunning the interrupted one"
}

test_complete_run_is_not_rerun() {
  local out
  wait_for 30 session_gone "$RUNNAME" || fail "the finished run's session should be gone"
  out=$(start 2>&1)
  assert_contains "$out" "already complete" "a finished run must say so"
  assert_equals 1 "$(run_count "$MARK/a.runs")" "a complete run must not run anything again"
  pass "a complete run is not rerun"
}

test_changed_inputs_are_refused_and_fresh_starts_over() {
  local out rc
  out=$(cd "$REPO" && "$REPO/bin/fm-test-detached.sh" --name "$RUNNAME" tests/a.test.sh 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "another selection"
  assert_contains "$out" "another selection" "a changed selection must be refused"
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m next
  out=$(start 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "another commit"
  assert_contains "$out" "another commit" "a record from another commit must be refused"
  out=$(start --fresh 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "fresh start"
  assert_contains "$out" "old record kept at $RUNDIR.prev-" "--fresh must keep the old record"
  assert_contains "$out" "0 of 3 scripts already finished" "--fresh starts over"
  wait_for 60 has_line "$RUNDIR" '^COMPLETE ' || fail "the fresh run never completed"
  assert_equals 2 "$(run_count "$MARK/a.runs")" "--fresh reruns every script"
  pass "a changed selection or commit is refused and --fresh starts over"
}

test_shared_server_socket_is_refused() {
  local out rc
  out=$(cd "$REPO" && FM_TEST_DETACHED_SOCKET=default "$REPO/bin/fm-test-detached.sh" --name refused "${SEL[@]}" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "the default socket"
  assert_contains "$out" "shared tmux server" "the shared server socket must be refused"
  assert_absent "$STATE/test-runs/refused" "a refused start must leave no record"
  [ -z "$(find "$SOCK_DIR" -name default)" ] || fail "a default tmux server was created"
  pass "the shared tmux server's socket name is refused"
}

test_unsupported_options_are_refused() {
  local option form out rc
  for option in --fail-on-gate-skip --per-script-timeout-secs --max-wall-ms --json --jobs --changed; do
    for form in "$option" "$option=value"; do
      out=$("$REPO/bin/fm-test-detached.sh" --name unsupported tests/a.test.sh "$form" 2>&1) && rc=0 || rc=$?
      expect_code 2 "$rc" "$form must be refused"
      assert_contains "$out" "unsupported detached option" "$form must explain refusal"
      assert_absent "$STATE/test-runs/unsupported" "refusal must leave no run record"
    done
  done
  pass "execution options are refused before starting a run"
}

test_same_name_in_another_home_runs_independently() {
  local out rc other="$FIXTURE/other-state"
  out=$(SEL=(tests/d.test.sh); FM_STATE_OVERRIDE="$other" start 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "same name in another home"
  assert_contains "$out" "started in tmux session" "another home must start its own run"
  wait_for 30 grep -q 'BEGIN .*tests/d.test.sh' "$other/test-runs/$RUNNAME/runner.log" || fail "another home did not execute d"
  out=$(FM_STATE_OVERRIDE="$other" "$REPO/bin/fm-test-detached.sh" --status "$RUNNAME" 2>&1)
  assert_contains "$out" "state=running" "another home must report its own running session"
  ptm kill-session -t "=fm-test-$(printf '%s/%s' "$(cd "$other/test-runs" && pwd -P)" "$RUNNAME" | git hash-object --stdin)" || fail "cannot stop other home run"
  ptm has-session -t "=$(session_name "$RUNNAME")" || fail "other home affected original run"
  pass "same named runs in separate homes execute independently"
}

test_relative_state_and_serialized_launch() {
  local out rc first second holder rel="$FIXTURE/relative-state" run=serialized
  mkdir -p "$rel/test-runs"
  python3 - "$rel/test-runs/.$run.lock" "$MARK" <<'PY' &
import fcntl
import pathlib
import sys
import time
with open(sys.argv[1], 'w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    mark = pathlib.Path(sys.argv[2])
    (mark / 'locked').touch()
    while not (mark / 'unlock').exists():
        time.sleep(0.05)
PY
  holder=$!
  wait_for 10 test -f "$MARK/locked" || fail "lock holder did not start"
  (cd "$FIXTURE" && FM_STATE_OVERRIDE=./relative-state "$REPO/bin/fm-test-detached.sh" --name "$run" --fresh tests/d.test.sh >"$MARK/first.out" 2>&1) &
  first=$!
  (cd "$FIXTURE" && FM_STATE_OVERRIDE=./relative-state "$REPO/bin/fm-test-detached.sh" --name "$run" tests/d.test.sh >"$MARK/second.out" 2>&1) &
  second=$!
  sleep 1
  assert_absent "$rel/test-runs/$run" "launchers must not prepare records while locked"
  : >"$MARK/unlock"
  wait "$holder" || fail "lock holder failed"
  wait "$first" && rc=0 || rc=$?
  case "$rc" in 0|2) ;; *) fail "fresh launcher failed unexpectedly" ;; esac
  wait "$second" || fail "ordinary launcher failed"
  wait_for 30 grep -q 'BEGIN .*tests/d.test.sh' "$rel/test-runs/$run/runner.log" || fail "relative-state worker did not execute"
  assert_equals 1 "$(grep -c '^BEGIN ' "$rel/test-runs/$run/runner.log")" "only one worker may launch"
  out=$(cd "$FIXTURE" && FM_STATE_OVERRIDE=./relative-state "$REPO/bin/fm-test-detached.sh" --status "$run")
  assert_contains "$out" 'state=running' "relative status must find the same session"
  ptm kill-session -t "=fm-test-$(printf '%s/%s' "$rel/test-runs" "$run" | git hash-object --stdin)" || fail "cannot stop relative run"
  pass "relative records survive detachment and launchers serialize record mutation"
}

test_relative_state_and_serialized_launch
test_unsupported_options_are_refused
test_runs_detached_on_a_private_socket
test_same_name_in_another_home_runs_independently
test_worker_environment
test_cut_off_run_resumes_without_rerunning_finished_files
test_complete_run_is_not_rerun
test_changed_inputs_are_refused_and_fresh_starts_over
test_shared_server_socket_is_refused
