#!/usr/bin/env bash
# Grok Stop-hook transport without launching a harness or supervision.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
mkdir -p "$TMP/bin"
export GROK_WORKSPACE_ROOT="$TMP" GROK_TURNEND_GUARD_ACTIVE=1 HOOK_FIXTURE="$TMP"
cat > "$TMP/bin/fm-turnend-guard.sh" <<'GUARD'
#!/usr/bin/env bash
cat > "$HOOK_FIXTURE/payload"
printf 'guard output\n'
printf 'guard diagnostic\n' >&2
exit "$(cat "$HOOK_FIXTURE/status")"
GUARD
chmod +x "$TMP/bin/fm-turnend-guard.sh"
printf '0\n' > "$TMP/status"

expect_native() {
  local payload=$1 status=$2 expected=$3 output rc
  printf '%s\n' "$status" > "$TMP/status"
  output=$(printf '%s' "$payload" | bash "$ROOT/bin/fm-turnend-guard-grok.sh" 2> "$TMP/stderr")
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "native status $status returned $rc"
  [ "$output" = 'guard output' ] || fail 'native stdout forwarding'
  [ "$(cat "$TMP/stderr")" = 'guard diagnostic' ] || fail 'native stderr forwarding'
  [ "$(cat "$TMP/payload")" = "$payload" ] || fail 'native payload forwarding'
}

expect_silent() {
  local payload=$1 output rc
  : > "$TMP/payload"
  output=$(printf '%s' "$payload" | bash "$ROOT/bin/fm-turnend-guard-grok.sh" 2> "$TMP/stderr")
  rc=$?
  [ "$rc" -eq 0 ] || fail "silent payload returned $rc"
  [ -z "$output" ] && [ ! -s "$TMP/stderr" ] || fail 'silent payload emitted output'
  [ ! -s "$TMP/payload" ] || fail 'silent payload invoked guard'
}

test_native() {
  expect_native '{"stopHookActive":true}' 0 0
  expect_native '{"stopHookActive":false}' 2 2
  expect_native '{"stop_hook_active":false}' 7 0
  expect_native '{"stopHookActive":true,"stop_hook_active":"ignored"}' 2 2
  pass 'typed native fields forward payload and diagnostics and normalize unexpected statuses'
}

test_invalid() {
  local payload
  for payload in '' '{' 'null' '[]' '{} {}' \
    '{"stopHookActive":"true"}' '{"stopHookActive":null}' \
    '{"stop_hook_active":1}' \
    '{"stopHookActive":"bad","stop_hook_active":true}' \
    '{"stopHookActive":true,"stopHookActive":false}' \
    '{"sessionId":"one","sessionId":"two","stopHookActive":true}'; do
    expect_silent "$payload"
  done
  pass 'empty, malformed, mistyped, duplicate and multiple payloads start neither path'
}

test_stand_down() {
  expect_silent '{"sessionId":"legacy-session"}'
  GROK_WORKSPACE_ROOT="$TMP/missing" expect_silent '{"stopHookActive":true}'
  pass 'recursive legacy calls and missing workspace guards stand down silently'
}

test_native
test_invalid
test_stand_down
