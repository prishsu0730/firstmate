#!/usr/bin/env bash
# Disposable lab home creation and private socket directories without a server.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
SOCKET_DIR=''
cleanup() {
  python3 -c 'import shutil, sys; [shutil.rmtree(p, ignore_errors=True) for p in sys.argv[1:] if p]' "$TMP" "$SOCKET_DIR"
}
trap cleanup EXIT
LAB="$TMP/lab home"
run() { bash "$ROOT/bin/fm-lab-home.sh" "$@"; }
refuses() {
  local expected=$1 actual
  shift
  run "$@" > "$TMP/out" 2> "$TMP/err"
  actual=$?
  [ "$actual" -eq "$expected" ] || fail "expected $expected, got $actual: $*"
  [ -s "$TMP/err" ] || fail "missing refusal diagnostic"
}

test_create() {
  local output child
  output=$(run create "$LAB") || fail "create"
  [ "$output" = "$LAB" ] || fail "printed path"
  [ "$(cat "$LAB/.fm-lab-home")" = 'fm-lab-home v1' ] || fail "lab marker"
  for child in state data config projects; do
    [ -d "$LAB/$child" ] || fail "missing stock directory $child"
  done
  refuses 1 create "$LAB"
  mkdir "$TMP/empty"
  run create "$TMP/empty" > "$TMP/out" || fail "existing empty directory"
  mkdir "$TMP/populated"
  printf 'keep\n' > "$TMP/populated/.hidden"
  refuses 1 create "$TMP/populated"
  [ ! -e "$TMP/populated/.fm-lab-home" ] || fail "marked populated directory"
  [ "$(cat "$TMP/populated/.hidden")" = keep ] || fail "changed existing content"
  printf 'keep\n' > "$TMP/file"
  refuses 1 create "$TMP/file"
  pass "creation marks fresh directories and preserves existing content on refusal"
}

test_usage() {
  local command
  refuses 2
  refuses 2 unknown
  for command in create tmux-dir teardown; do
    refuses 2 "$command"
  done
  for command in tmux-dir teardown; do
    refuses 1 "$command" "$TMP/absent"
    refuses 1 "$command" "$TMP/populated"
  done
  pass "usage and unmarked home refusals have distinct exit codes"
}

test_socket_directory() {
  local output mode
  SOCKET_DIR=$(run tmux-dir "$LAB") || fail "socket directory creation"
  case "$SOCKET_DIR" in /tmp/fml.??????) ;; *) fail "socket directory format" ;; esac
  [ -d "$SOCKET_DIR" ] && [ ! -L "$SOCKET_DIR" ] || fail "unsafe socket directory"
  mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$SOCKET_DIR")
  [ "$mode" = 0o700 ] || fail "socket directory permissions"
  [ "$(cat "$LAB/state/.fm-lab-tmux-dir")" = "$SOCKET_DIR" ] || fail "socket record"
  output=$(run tmux-dir "$LAB") || fail "socket directory reuse"
  [ "$output" = "$SOCKET_DIR" ] || fail "socket directory was replaced"
  chmod 755 "$SOCKET_DIR"
  refuses 1 tmux-dir "$LAB"
  refuses 1 teardown "$LAB"
  [ -d "$SOCKET_DIR" ] || fail "removed nonprivate directory"
  chmod 700 "$SOCKET_DIR"
  run teardown "$LAB" || fail "empty socket directory teardown"
  [ ! -e "$SOCKET_DIR" ] || fail "socket directory survived teardown"
  [ ! -e "$LAB/state/.fm-lab-tmux-dir" ] || fail "socket record survived teardown"
  SOCKET_DIR=''
  run teardown "$LAB" || fail "idempotent teardown"
  [ -f "$LAB/.fm-lab-home" ] || fail "teardown removed home"
  pass "private socket directories are reused, checked, and removed idempotently"
}

test_invalid_record() {
  printf '/unsafe/socket\n' > "$LAB/state/.fm-lab-tmux-dir"
  refuses 1 tmux-dir "$LAB"
  refuses 1 teardown "$LAB"
  [ "$(cat "$LAB/state/.fm-lab-tmux-dir")" = /unsafe/socket ] || fail "changed rejected record"
  pass "invalid socket paths refuse without rewriting the record"
}

test_create
test_usage
test_socket_directory
test_invalid_record
