#!/usr/bin/env bash
# Scope-map command argument and output validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
BRIEF="$TMP/brief"

run_command() {
  bash "$ROOT/bin/fm-scope-map.sh" "$@" > "$TMP/out" 2> "$TMP/err"
  RC=$?
}

test_usage() {
  local option
  for option in -h --help; do
    run_command "$option"
    [ "$RC" -eq 0 ] || fail "help status"
    [ ! -s "$TMP/err" ] || fail "help stderr"
    [[ $(cat "$TMP/out") == *'Usage: fm-scope-map.sh items <brief>'* ]] || fail "help usage"
  done
  for option in '' unknown items check; do
    run_command "$option"
    [ "$RC" -eq 2 ] || fail "invalid invocation status: $option"
    [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ] || fail "usage streams"
  done
  run_command items "$BRIEF" extra
  [ "$RC" -eq 2 ] || fail "items extra argument"
  run_command check brief map worktree base extra
  [ "$RC" -eq 2 ] || fail "check extra argument"
  pass "help and invalid argument counts use the expected status and streams"
}

test_items() {
  cat > "$BRIEF" <<'BRIEF'
## Captain's intent
- First task
## Firstmate spec
1. Second task
BRIEF
  run_command items "$BRIEF"
  [ "$RC" -eq 0 ] && [ ! -s "$TMP/err" ] || fail "items status and stderr"
  [ "$(cat "$TMP/out"; printf sentinel)" = $'I1\tFirst task\nS1\tSecond task\nsentinel' ] || fail "items exact output"
  run_command items "$TMP/missing"
  [ "$RC" -eq 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || fail "missing items input"
  pass "items dispatch prints keyed lines and accepts a missing brief silently"
}

test_check() {
  run_command check "$BRIEF" "$TMP/missing" "$TMP"
  [ "$RC" -eq 0 ] && [ ! -s "$TMP/err" ] || fail "legacy brief check"
  [ "$(cat "$TMP/out"; printf sentinel)" = $'scope map complete\nsentinel' ] || fail "complete output"
  printf '# Scope map\n' >> "$BRIEF"
  run_command check "$BRIEF" "$TMP/missing" "$TMP" main
  [ "$RC" -eq 1 ] && [ ! -s "$TMP/err" ] || fail "non-worktree check status"
  [ "$(cat "$TMP/out")" = $'I1 cannot be checked without a git worktree (First task)\nS1 cannot be checked without a git worktree (Second task)' ] || fail "non-worktree diagnostics"
  printf '# Scope map\n' > "$BRIEF"
  run_command check "$BRIEF" "$TMP/missing" "$TMP"
  [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = 'scope map complete' ] || fail "empty scope check"
  pass "checks accept legacy and empty briefs and refuse scoped items outside a worktree"
}

test_usage
test_items
test_check
