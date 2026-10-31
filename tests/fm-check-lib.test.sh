#!/usr/bin/env bash
# Pure custom-check checksum validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

test_empty_checksum() {
  local got rc
  got=$(fm_custom_check_sha256 /dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "empty checksum status"
  [ "$got" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ] || fail "empty checksum"
  pass "empty file has the standard SHA-256 digest"
}

test_content_checksum() {
  local got rc
  got=$(printf abc | fm_custom_check_sha256 /dev/stdin); rc=$?
  [ "$rc" -eq 0 ] || fail "content checksum status"
  [ "$got" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ] || fail "content checksum"
  got=$(printf 'abc\n' | fm_custom_check_sha256 /dev/stdin); rc=$?
  [ "$rc" -eq 0 ] || fail "newline checksum status"
  [ "$got" = edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb ] || fail "newline checksum"
  pass "content bytes and trailing newlines produce distinct standard digests"
}

test_checksum_output() {
  local got rc
  got=$(fm_custom_check_sha256 /dev/null; printf sentinel); rc=$?
  [ "$rc" -eq 0 ] || fail "output status"
  [ "$got" = $'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\nsentinel' ] || fail "digest output newline"
  pass "output contains only the digest and one final newline"
}

test_checksum_tools_unavailable() {
  local got rc
  got=$(PATH='' fm_custom_check_sha256 /dev/null 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "unavailable checksum tools status"
  [ -z "$got" ] || fail "unavailable checksum tools output"
  pass "missing checksum tools return failure without output"
}

test_empty_checksum
test_content_checksum
test_checksum_output
test_checksum_tools_unavailable
