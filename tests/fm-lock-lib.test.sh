#!/usr/bin/env bash
# Lock timestamp helpers and early refusal without process inspection.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-lock-lib.sh
. "$ROOT/bin/fm-lock-lib.sh"

test_real_timestamp() {
  local path mtime before after age got rc
  path="$ROOT/tests/fm-lock-lib.test.sh"
  mtime=$(fm_lock_path_mtime "$path"); rc=$?
  [ "$rc" -eq 0 ] || fail 'existing file mtime'
  case "$mtime" in ''|*[!0-9]*) fail 'mtime must be epoch seconds' ;; esac
  before=$(date +%s)
  age=$(fm_lock_age "$path"); rc=$?
  after=$(date +%s)
  [ "$rc" -eq 0 ] || fail 'existing file age'
  [ "$age" -ge "$((before - mtime))" ] &&
    [ "$age" -le "$((after - mtime))" ] || fail 'age agrees with real mtime'
  got=$(fm_lock_path_mtime "$path"; printf '|')
  [ "$got" = "$mtime"$'\n|' ] || fail 'mtime newline'
  pass 'real file mtime and age use epoch seconds with newline output'
}

test_missing_paths() {
  local path got rc
  for path in '' /dev/null/firstmate-missing-lock; do
    got=$(fm_lock_path_mtime "$path" 2>&1); rc=$?
    [ "$rc" -ne 0 ] && [ -z "$got" ] || fail 'missing mtime refuses silently'
    got=$(fm_lock_age "$path" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'missing age refuses silently'
    got=$(fm_lock_is_provably_stale "$path" '' 0 2>&1); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'missing lock is never stale'
  done
  pass 'empty and impossible paths refuse before process inspection'
}

test_log_format() {
  local got
  got=$(unset FM_LOCK_LOG_PREFIX; fm_lock_log hello world 2>&1 >/dev/null)
  [ "$got" = 'fm-lock: hello world' ] || fail 'default stderr prefix'
  got=$(FM_LOCK_LOG_PREFIX=custom fm_lock_log 'lock path' 2>&1 >/dev/null)
  [ "$got" = 'custom: lock path' ] || fail 'custom stderr prefix'
  got=$(FM_LOCK_LOG_PREFIX='' fm_lock_log 2>&1 >/dev/null)
  [ "$got" = 'fm-lock: ' ] || fail 'empty prefix fallback'
  got=$(fm_lock_log hello 2>/dev/null)
  [ -z "$got" ] || fail 'log stdout must be empty'
  pass 'logs use stderr with default, custom, and empty-prefix fallback formatting'
}

test_real_timestamp
test_missing_paths
test_log_format
