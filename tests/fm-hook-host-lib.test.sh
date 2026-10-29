#!/usr/bin/env bash
# Hook payload classification without running a harness or hook entrypoint.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-hook-host-lib.sh
. "$ROOT/bin/fm-hook-host-lib.sh"
command -v jq >/dev/null 2>&1 || fail 'jq is required'

assert_foreign() {
  fm_hook_payload_is_foreign_host "$1" || fail "foreign payload [$1]"
}
assert_local() {
  if fm_hook_payload_is_foreign_host "$1"; then
    fail "unrecognized payload [$1]"
  fi
}

test_string_marker() {
  assert_foreign '{"cursor_version":"2026.08.11"}'
  assert_foreign '{"cursor_version":""}'
  assert_foreign '{"cursor_version":"unknown","hook_event_name":"PreToolUse"}'
  pass 'top-level string markers are accepted regardless of value or extra fields'
}

test_rejected_payloads() {
  local payload
  for payload in '' '{}' 'null' 'true' '42' '"cursor_version"' '[]' \
    '{"cursor_version":null}' '{"cursor_version":1}' \
    '{"cursor_version":true}' '{"cursor_version":[]}' \
    '{"cursor_version":{}}' '{"nested":{"cursor_version":"v1"}}' \
    '[{"cursor_version":"v1"}]' '{"cursor_version":' 'not json'; do
    assert_local "$payload"
  done
  if fm_hook_payload_is_foreign_host; then fail 'missing argument'; fi
  pass 'missing, malformed, nested and nonstring markers are rejected'
}

test_environment_and_output() {
  local got
  export CURSOR_INVOKED_AS=cursor CURSOR_PROJECT_DIR=/unused CURSOR_VERSION=v1
  assert_local '{"hook_event_name":"PreToolUse"}'
  assert_foreign '{"cursor_version":"v1"}'
  got=$(fm_hook_payload_is_foreign_host '{"cursor_version":"v1"}' 2>&1)
  [ -z "$got" ] || fail 'accepted payload prints nothing'
  got=$(fm_hook_payload_is_foreign_host 'invalid' 2>&1)
  [ -z "$got" ] || fail 'invalid payload prints nothing'
  pass 'inherited environment does not classify payloads and predicates stay silent'
}

test_string_marker
test_rejected_payloads
test_environment_and_output
