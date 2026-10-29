#!/usr/bin/env bash
# Confined file reads without a remote host or backend.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_HOME="$TMP/home"
export STATE="$TMP/home/state"
mkdir -p "$FM_HOME/files" "$TMP/outside"
printf 'hello\n' > "$FM_HOME/files/message"
: > "$FM_HOME/files/empty"
printf 'private\n' > "$TMP/outside/secret"

run() { bash "$ROOT/bin/fm-remote-file.sh" "$@" > "$TMP/out" 2> "$TMP/err"; }
refuse() {
  local expected=$1
  shift
  run "$@" && fail "unsafe read accepted: $*"
  [ ! -s "$TMP/out" ] || fail "refusal leaked file bytes"
  grep -Fq "$expected" "$TMP/err" || fail "missing diagnostic: $expected"
}

test_reads() {
  run get files/message 6 || fail "exact byte limit"
  cmp -s "$TMP/out" "$FM_HOME/files/message" || fail "file bytes changed"
  run get files/empty 1 || fail "empty file"
  [ ! -s "$TMP/out" ] || fail "empty file output"
  run get files/message || fail "default byte limit"
  cmp -s "$TMP/out" "$FM_HOME/files/message" || fail "default output"
  refuse 'file exceeds max-bytes' get files/message 5
  pass "reads preserve bytes and enforce the inclusive size limit"
}

test_paths() {
  local path
  for path in '' /etc/passwd files//message; do
    refuse 'path must be a nonempty relative path' get "$path"
  done
  for path in ../outside/secret files/../files/message ./files/message; do
    refuse 'path traversal is not allowed' get "$path"
  done
  refuse 'path contains control characters' get $'files/mes\tsage'
  refuse 'file parent is unavailable' get missing/message
  refuse 'file is not a non-symlink regular file' get files
  refuse 'file is not a non-symlink regular file' get files/missing
  ln -s "$FM_HOME/files/message" "$FM_HOME/files/link"
  refuse 'file is not a non-symlink regular file' get files/link
  ln -s "$TMP/outside" "$FM_HOME/escape"
  refuse 'file escapes FM_HOME' get escape/secret
  pass "traversal, missing files, directories and escaping symlinks are refused"
}

test_arguments() {
  local limit
  for limit in 0 -1 abc; do
    refuse 'max-bytes must be a positive integer' get files/message "$limit"
  done
  refuse 'max-bytes exceeds the 1048576-byte safety bound' get files/message 1048577
  run get files/message 6 extra && fail "extra argument accepted"
  run unknown files/message && fail "unknown command accepted"
  pass "invalid byte bounds and command shapes are refused"
}

test_reads
test_paths
test_arguments
echo '# fm-remote-file.test.sh: all assertions passed'
