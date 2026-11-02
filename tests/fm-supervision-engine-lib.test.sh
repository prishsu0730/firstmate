#!/usr/bin/env bash
# Engine result parsing without running an engine or supervision host.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$ROOT/bin/fm-supervision-engine-lib.sh"

write_result() {
  cat > "$TMP/result.json" <<'JSON'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.75,"num_turns":2,"usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":40}}
JSON
}
parse() { fm_supervision_engine_result claude "$TMP/result.json" "$@"; }

test_success() {
  local expected prior
  write_result
  expected='error=0 cost=0.75 conversation_cost=0.75 input=10 cache_read=20 cache_write=30 output=40 turns=2'
  [ "$(parse)" = "$expected" ] || fail 'complete result framing'
  [ "$(parse 0.25)" = 'error=0 cost=0.5 conversation_cost=0.75 input=10 cache_read=20 cache_write=30 output=40 turns=2' ] || fail 'resumed turn cost'
  [ "$(parse 0.75)" = 'error=0 cost=0 conversation_cost=0.75 input=10 cache_read=20 cache_write=30 output=40 turns=2' ] || fail 'unchanged conversation cost'
  for prior in -1 1 invalid; do
    [ "$(parse "$prior")" = "$expected" ] || fail "invalid prior cost: $prior"
  done
  pass 'complete results report usage and resumed costs with invalid-prior fallback'
}

test_incomplete() {
  local field out
  for field in type subtype is_error total_cost_usd num_turns input_tokens cache_read_input_tokens cache_creation_input_tokens output_tokens; do
    write_result
    node -e '
      const fs = require("node:fs");
      const [path, field] = process.argv.slice(1);
      const j = JSON.parse(fs.readFileSync(path, "utf8"));
      if (field.endsWith("tokens")) delete j.usage[field];
      else delete j[field];
      fs.writeFileSync(path, JSON.stringify(j));
    ' "$TMP/result.json" "$field" || fail 'prepare incomplete result'
    out=$(parse) || fail "incomplete result should retain metrics: $field"
    case "$out" in error=1\ *) ;; *) fail "missing field accepted: $field" ;; esac
  done
  printf '%s\n' '{"total_cost_usd":"0.75","num_turns":null,"usage":{"input_tokens":"10","output_tokens":false}}' > "$TMP/result.json"
  [ "$(parse)" = 'error=1 cost=0 conversation_cost=0 input=0 cache_read=0 cache_write=0 output=0 turns=0' ] || fail 'nonnumeric metrics fallback'
  printf '%s\n' '{"type":"result","subtype":"error","is_error":true}' > "$TMP/result.json"
  case "$(parse)" in error=1\ *) ;; *) fail 'failed result accepted' ;; esac
  pass 'incomplete and failed results are flagged and nonnumeric metrics become zero'
}

test_unreadable() {
  local payload out rc
  for payload in '' '{' null '"text"'; do
    printf '%s' "$payload" > "$TMP/result.json"
    out=$(parse)
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$out" ] || fail 'malformed result must fail silently'
  done
  out=$(fm_supervision_engine_result claude "$TMP/missing.json")
  rc=$?
  [ "$rc" -eq 1 ] && [ -z "$out" ] || fail 'missing result must fail silently'
  out=$(fm_supervision_engine_result unsupported "$TMP/result.json")
  rc=$?
  [ "$rc" -eq 1 ] && [ -z "$out" ] || fail 'unsupported engine must fail silently'
  pass 'invalid JSON, nonobjects, missing files and unsupported engines fail without output'
}

test_success
test_incomplete
test_unreadable
