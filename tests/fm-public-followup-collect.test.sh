#!/usr/bin/env bash
# Hermetic collection and retirement of staged public follow-up events.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

COLLECT="$ROOT/bin/fm-public-followup-collect.sh"
TMP_ROOT=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP_ROOT"' EXIT
export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$TMP_ROOT/events"
OUTBOX="$FM_STATE_OVERRIDE/public-followup/outbox"

run_collect() {
  local expected=$1 rc
  shift
  bash "$COLLECT" "$@" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "collector status $rc instead of $expected"
}

test_usage() {
  run_collect 2
  run_collect 2 unknown
  run_collect 2 drain ../unsafe
  run_collect 2 drop valid ../unsafe
  run_collect 0 --help
  [ -s "$TMP_ROOT/stdout" ] || fail "help missing"
  pass "usage and unsafe identifiers refuse and help succeeds"
}

test_drain() {
  run_collect 0 drain wanted
  [ ! -s "$TMP_ROOT/stdout" ] || fail "absent outbox returned events"
  mkdir -p "$OUTBOX"
  printf '{ "obligation_id": "wanted", "value": 1 }\n' > "$OUTBOX/good.json"
  printf '{"obligation_id":"other"}\n' > "$OUTBOX/other.json"
  printf 'broken\n' > "$OUTBOX/broken.json"
  printf '{"obligation_id":"wanted"}\n' > "$OUTBOX/.hidden.json"
  ln -s "$OUTBOX/good.json" "$OUTBOX/link.json"
  mkdir "$OUTBOX/directory.json"
  run_collect 0 drain wanted
  [ "$(cat "$TMP_ROOT/stdout")" = '{"obligation_id":"wanted","value":1}' ] || fail "drain selection or compaction"
  grep -q 'broken.*not readable JSON' "$TMP_ROOT/stderr" || fail "broken event diagnostic"
  [ -f "$OUTBOX/good.json" ] && [ -f "$OUTBOX/broken.json" ] || fail "drain removed events"
  FM_PF_EVENT_BYTES_MAX=1 run_collect 0 drain wanted
  [ ! -s "$TMP_ROOT/stdout" ] || fail "oversized events returned"
  grep -q 'exceeds 1 bytes' "$TMP_ROOT/stderr" || fail "oversized event diagnostic"
  pass "drain selects record ownership, retains events, and skips unsafe or malformed entries"
}

test_drop() {
  run_collect 1 drop wrong good
  [ -f "$OUTBOX/good.json" ] || fail "mismatched obligation removed event"
  run_collect 1 drop wanted broken
  [ -f "$OUTBOX/broken.json" ] || fail "broken event removed"
  run_collect 0 drop wanted link
  [ -L "$OUTBOX/link.json" ] || fail "symlink removed"
  run_collect 0 drop wanted good
  [ ! -e "$OUTBOX/good.json" ] || fail "matching event retained"
  run_collect 0 drop wanted good
  [ -f "$OUTBOX/other.json" ] || fail "unrelated event removed"
  pass "drop requires matching ownership, ignores symlinks, and permits repeated retirement"
}

test_unsafe_outbox() {
  export FM_STATE_OVERRIDE="$TMP_ROOT/unsafe"
  mkdir -p "$FM_STATE_OVERRIDE/public-followup"
  ln -s "$OUTBOX" "$FM_STATE_OVERRIDE/public-followup/outbox"
  run_collect 1 drain wanted
  grep -q 'not a safely readable directory' "$TMP_ROOT/stderr" || fail "unsafe outbox diagnostic"
  pass "drain refuses a symlinked outbox"
}

test_usage
test_drain
test_drop
test_unsafe_outbox
