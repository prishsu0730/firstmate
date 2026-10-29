#!/usr/bin/env bash
# Session-open routing with isolated eligibility and digest dependencies.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-sessionstart-run.sh" "$TMP/fm-sessionstart-run.sh"
export ROUTE_FIXTURE="$TMP" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records"
mkdir -p "$FM_STATE_OVERRIDE"
cat > "$TMP/fm-gate-refuse-lib.sh" <<'STUB'
fm_is_gate_agent() { [ "${TEST_GATE:-0}" = 1 ]; }
STUB
cat > "$TMP/fm-primary-scope-lib.sh" <<'STUB'
fm_primary_root_matches() { return 0; }
fm_primary_scope_matches() { [ "${TEST_SCOPE:-1}" = 1 ]; }
STUB
cat > "$TMP/fm-session-lock-lib.sh" <<'STUB'
fm_session_lock_owned_by_self() { [ "${TEST_OWNER:-1}" = 1 ]; }
STUB
cat > "$TMP/fm-hook-host-lib.sh" <<'STUB'
fm_hook_payload_is_foreign_host() { [ "${TEST_FOREIGN:-0}" = 1 ]; }
STUB
cat > "$TMP/fm-session-start.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' digest "$@" > "$ROUTE_FIXTURE/args"
printf 'digest output\n'
exit "${TEST_DIGEST_STATUS:-0}"
STUB
cat > "$TMP/fm-sessionstart-nudge.sh" <<'STUB'
#!/usr/bin/env bash
printf 'nudge\n' > "$ROUTE_FIXTURE/args"
STUB
chmod +x "$TMP/fm-session-start.sh" "$TMP/fm-sessionstart-nudge.sh"
run() { bash "$TMP/fm-sessionstart-run.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"; }
expect_args() { [ "$(cat "$TMP/args")" = "$(printf '%s\n' "$@")" ] || fail 'routing arguments'; }

test_sources() {
  local source
  for source in startup new unknown; do
    run --source "$source" < /dev/null || fail 'full digest status'
    expect_args digest --source "$source"
  done
  for source in resume reload fork; do
    run --source="$source" < /dev/null || fail 'nudge status'
    expect_args nudge
  done
  printf '{"note":"source","source":"compact"}' | run || fail 'payload status'
  expect_args digest --source compact
  run --source < /dev/null || fail 'bare source status'
  expect_args digest --source ''
  TEST_DIGEST_STATUS=7 run --source startup < /dev/null || fail 'digest error escaped hook'
  [ "$(cat "$TMP/stdout")" = 'digest output' ] || fail 'digest output lost'
  pass 'explicit and payload sources route to digest or nudge and digest failures remain compatible'
}

test_completion() {
  local source
  printf '123\n' > "$FM_STATE_OVERRIDE/.lock"
  printf '123\n' > "$FM_STATE_OVERRIDE/.session-start-complete"
  for source in clear compact; do
    run --source "$source" < /dev/null || fail 'reemit status'
    expect_args digest --reemit --source "$source"
    TEST_OWNER=0 run --source "$source" < /dev/null || fail 'nonowner status'
    expect_args digest --source "$source"
  done
  printf '456\n' > "$FM_STATE_OVERRIDE/.session-start-complete"
  run --source clear < /dev/null || fail 'mismatched completion status'
  expect_args digest --source clear
  printf 'bad\n' > "$FM_STATE_OVERRIDE/.lock"
  printf 'bad\n' > "$FM_STATE_OVERRIDE/.session-start-complete"
  run --source compact < /dev/null || fail 'malformed lock status'
  expect_args digest --source compact
  pass 'reemit requires matching numeric completion and self-owned lock'
}

test_stand_down() {
  local rc
  printf 'untouched\n' > "$TMP/args"
  TEST_GATE=1 run --source startup < /dev/null || fail 'ordinary gate status'
  TEST_SCOPE=0 run --source startup < /dev/null || fail 'ordinary scope status'
  TEST_GATE=1 run --pi-prerequisite --source startup < /dev/null
  rc=$?
  [ "$rc" -eq 3 ] || fail 'Pi gate status'
  TEST_SCOPE=0 run --pi-prerequisite --source startup < /dev/null
  rc=$?
  [ "$rc" -eq 3 ] || fail 'Pi scope status'
  printf '{"source":"startup"}' | TEST_FOREIGN=1 run || fail 'foreign payload status'
  expect_args untouched
  [ ! -s "$TMP/stdout" ] || fail 'stand-down output'
  pass 'gate, scope and duplicate foreign-host invocations stand down without dispatch'
}

test_sources
test_completion
test_stand_down
