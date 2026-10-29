#!/usr/bin/env bash
# Pure nudge marker and transaction lock path validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$ROOT/bin/fm-secondmate-nudge-lib.sh"

test_valid_ids() {
  local id got
  for id in mate A_Z-09.example . ..; do
    got=$(fm_secondmate_nudge_marker_path '/path with spaces' "$id") || fail "marker status: $id"
    [ "$got" = "/path with spaces/.secondmate-nudge-pending/$id.pending" ] || fail "marker path: $id"
    got=$(fm_remote_inherit_transaction_lock_path '/path with spaces' "$id") || fail "lock status: $id"
    [ "$got" = "/path with spaces/.remote-inherit-$id.lock" ] || fail "lock path: $id"
  done
  pass "allowed identifiers remain literal within marker and lock paths"
}

test_invalid_ids() {
  local id helper got rc
  for helper in fm_secondmate_nudge_marker_path fm_remote_inherit_transaction_lock_path; do
    for id in '' /mate mate/child ../mate 'two mates' $'mate\n' $'mate\r' $'mate\t' 'mate!' '世界'; do
      got=$("$helper" /unused "$id"); rc=$?
      [ "$rc" -eq 1 ] || fail "$helper rejects invalid identifier: [$id]"
      [ -z "$got" ] || fail "$helper rejection is silent"
    done
  done
  pass "empty, separator, whitespace, punctuation, and Unicode identifiers are refused silently"
}

test_path_output() {
  local got
  got=$(fm_secondmate_nudge_marker_path '' mate; printf sentinel)
  [ "$got" = $'/.secondmate-nudge-pending/mate.pending\nsentinel' ] || fail "empty state and marker newline"
  got=$(fm_remote_inherit_transaction_lock_path /root/ mate; printf sentinel)
  [ "$got" = $'/root//.remote-inherit-mate.lock\nsentinel' ] || fail "trailing separator and lock newline"
  pass "state paths are preserved literally and results end with one newline"
}

test_write_input_guards() {
  local remote field value got rc home commit instructions message
  for remote in '' 2 true remote; do
    got=$(fm_secondmate_nudge_write /unused mate home commit instructions message "$remote" 2>&1); rc=$?
    [ "$rc" -eq 1 ] || fail "invalid remote flag: [$remote]"
    [ -z "$got" ] || fail "invalid remote flag is silent"
  done
  for field in home commit instructions message; do
    for value in $'line\nbreak' $'line\rbreak'; do
      home=home commit=commit instructions=instructions message=message
      case "$field" in
        home) home=$value ;;
        commit) commit=$value ;;
        instructions) instructions=$value ;;
        message) message=$value ;;
      esac
      for remote in 0 1; do
        got=$(fm_secondmate_nudge_write /unused mate "$home" "$commit" "$instructions" "$message" "$remote" 2>&1); rc=$?
        [ "$rc" -eq 1 ] || fail "record separator in $field with remote=$remote"
        [ -z "$got" ] || fail "record separator rejection is silent"
      done
    done
  done
  pass "invalid remote flags and record separators fail silently before writing"
}

test_valid_ids
test_invalid_ids
test_path_output
test_write_input_guards
