#!/usr/bin/env bash
# Private Devin configuration generation without launching a worker.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
OUTPUT="$TMP/task.devin-config.json"

test_absent_source() {
  FM_KEEP_AI_TRAILERS=0 bash "$ROOT/bin/fm-devin-config.sh" "$TMP" task generation "$TMP/absent" || fail "absent source status"
  jq -e '
    .attribution == false and .read_config_from.claude == false and
    ([.hooks.UserPromptSubmit, .hooks.Stop, .hooks.SessionEnd] |
      all(length == 1 and .[0].hooks[0].type == "command" and .[0].hooks[0].timeout == 10))
  ' "$OUTPUT" >/dev/null || fail "default settings and hook structure"
  python3 - "$OUTPUT" <<'PY' || fail "private file mode"
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
  pass "absent source generates private defaults and three command hooks"
}

test_preserved_settings() {
  local source="$TMP/source.json" before
  printf '%s\n' '{"attribution":true,"custom":{"value":42},"read_config_from":{"agents":true,"claude":true},"hooks":{"Stop":[{"existing":true}],"Other":[{"untouched":true}]}}' > "$source"
  before=$(cat "$source")
  FM_KEEP_AI_TRAILERS=0 bash "$ROOT/bin/fm-devin-config.sh" "$TMP" task generation "$source" || fail "source config status"
  jq -e '
    .attribution == false and .custom.value == 42 and
    .read_config_from == {agents:true,claude:false} and
    .hooks.Stop[0].existing == true and (.hooks.Stop | length) == 2 and
    .hooks.Other == [{untouched:true}]
  ' "$OUTPUT" >/dev/null || fail "preserved settings and appended hooks"
  FM_KEEP_AI_TRAILERS=1 bash "$ROOT/bin/fm-devin-config.sh" "$TMP" task generation "$source" || fail "keep attribution status"
  jq -e '.attribution == true and (.hooks.Stop | length) == 2' "$OUTPUT" >/dev/null || fail "attribution opt-in or replacement"
  [ "$(cat "$source")" = "$before" ] || fail "source changed"
  pass "user settings survive, hooks append, and attribution opt-in is honored"
}

test_refused_inputs() {
  local value before
  before=$(cat "$OUTPUT")
  for value in 'invalid json' '[]' 'null' '{} {}'; do
    printf '%s\n' "$value" > "$TMP/invalid.json"
    if bash "$ROOT/bin/fm-devin-config.sh" "$TMP" task generation "$TMP/invalid.json" > "$TMP/stdout" 2> "$TMP/stderr"; then
      fail "invalid source accepted: $value"
    fi
    [ "$(cat "$OUTPUT")" = "$before" ] || fail "failed generation changed destination"
  done
  if bash "$ROOT/bin/fm-devin-config.sh" "$TMP" '../escape' generation "$TMP/absent" > "$TMP/stdout" 2> "$TMP/stderr"; then
    fail "invalid task id accepted"
  fi
  if bash "$ROOT/bin/fm-devin-config.sh" "$TMP/missing" task generation "$TMP/absent" > "$TMP/stdout" 2> "$TMP/stderr"; then
    fail "missing directory accepted"
  fi
  [ -z "$(find "$TMP" -name '.task.devin-config.*' -print)" ] || fail "temporary output survived refusal"
  pass "invalid inputs fail without replacing output or leaving temporary files"
}

test_absent_source
test_preserved_settings
test_refused_inputs
