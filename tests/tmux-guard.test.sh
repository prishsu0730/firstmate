#!/usr/bin/env bash
# tests/tmux-guard.test.sh - tests/tmux-guard/tmux refuses any tmux call that
# would reach the operator's live default server and passes every other call on.
# A stub stands in for the real tmux, so this test never touches a tmux server.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD_DIR="$ROOT/tests/tmux-guard"
TMP_ROOT=$(fm_test_tmproot tmux-guard)
STUB_DIR="$TMP_ROOT/stub"
mkdir -p "$STUB_DIR" "$TMP_ROOT/private"
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'REAL %s\n' "$*"
STUB
chmod +x "$STUB_DIR/tmux"

# The guard runs first on PATH and finds the stub as the "real" tmux.
GUARD_PATH="$GUARD_DIR:$STUB_DIR:/usr/bin:/bin"

# run_guard <env assignment...> -- <tmux args...>; prints stdout, sets RC.
run_guard() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  set +e
  OUT=$(env -u TMUX -u TMUX_TMPDIR -u FM_TEST_ALLOW_LIVE_TMUX ${envs[@]+"${envs[@]}"} PATH="$GUARD_PATH" "$GUARD_DIR/tmux" "$@" 2>"$TMP_ROOT/err")
  RC=$?
  set -e
}

expect_refused() {  # <label> <env...> -- <tmux args...>
  local label=$1; shift
  run_guard "$@"
  [ "$RC" -ne 0 ] || fail "$label: live-socket call was allowed"
  [ -z "$OUT" ] || fail "$label: refused call still reached tmux ($OUT)"
  grep -q 'tmux-guard: refused' "$TMP_ROOT/err" || fail "$label: no refusal message"
  pass "$label: refused"
}

expect_passed() {  # <label> <env...> -- <tmux args...>
  local label=$1; shift
  run_guard "$@"
  [ "$RC" -eq 0 ] || fail "$label: safe call was refused ($(cat "$TMP_ROOT/err"))"
  case "$OUT" in REAL*) ;; *) fail "$label: call did not reach tmux ($OUT)" ;; esac
  pass "$label: passed"
}

expect_refused "TMUX_TMPDIR unset" -- kill-server
expect_refused "TMUX_TMPDIR empty" TMUX_TMPDIR= -- kill-server
expect_refused "TMUX_TMPDIR names a missing directory" TMUX_TMPDIR="$TMP_ROOT/gone" -- kill-server
expect_refused "-L default with no private dir" -- -L default kill-server
expect_refused "-S names the live socket" -- -S "/tmp/tmux-$(id -u)/default" kill-server
expect_refused "TMUX points at the live socket" TMUX="/tmp/tmux-$(id -u)/default,1,0" -- display-message

expect_passed "TMUX_TMPDIR names a real directory" TMUX_TMPDIR="$TMP_ROOT/private" -- kill-server
expect_passed "-S names a private socket" -- -S "$TMP_ROOT/private/sock" kill-server
expect_passed "-V needs no server" -- -V

run_guard FM_TEST_ALLOW_LIVE_TMUX=1 -- kill-server
{ [ "$RC" -eq 0 ] && [ "$OUT" = "REAL kill-server" ]; } || fail "FM_TEST_ALLOW_LIVE_TMUX did not opt out"
pass "FM_TEST_ALLOW_LIVE_TMUX opts out"

# tests/lib.sh puts the guard first on PATH for every suite.
case "$(PATH="$STUB_DIR:/usr/bin:/bin" bash -c ". '$ROOT/tests/lib.sh'; printf %s \"\$PATH\"")" in
  "$GUARD_DIR":*) pass "lib.sh puts the guard first on PATH" ;;
  *) fail "lib.sh did not put the guard first on PATH" ;;
esac
