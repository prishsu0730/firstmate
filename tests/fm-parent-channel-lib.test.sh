#!/usr/bin/env bash
# Parent channel identity, line framing, and safe append behavior without services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$ROOT/bin/fm-parent-channel-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT

expect_identity() {
  local expected_status=$1 expected_output=$2 output rc
  output=$(fm_parent_channel_home_id "$TMP/home")
  rc=$?
  [ "$rc" -eq "$expected_status" ] || fail "identity status: $rc instead of $expected_status"
  [ "$output" = "$expected_output" ] || fail "identity output"
}

test_identity() {
  local id
  mkdir "$TMP/home"
  expect_identity 1 ''
  for id in mate mate-2 mate.name_3 A9; do
    printf '%s\n' "$id" > "$TMP/home/.fm-secondmate-home"
    expect_identity 0 "$id"
  done
  for id in '' .hidden ../mate 'two words' 'mate/name' $'mate\nother' $'mate\r'; do
    printf '%s' "$id" > "$TMP/home/.fm-secondmate-home"
    expect_identity 2 ''
  done
  printf 'mate\000hidden' > "$TMP/home/.fm-secondmate-home"
  expect_identity 2 ''
  mkdir "$TMP/directory-home"
  mkdir "$TMP/directory-home/.fm-secondmate-home"
  fm_parent_channel_home_id "$TMP/directory-home" >/dev/null && fail "directory identity accepted"
  mkdir "$TMP/link-home"
  ln -s "$TMP/home/.fm-secondmate-home" "$TMP/link-home/.fm-secondmate-home"
  fm_parent_channel_home_id "$TMP/link-home" >/dev/null && fail "symlink identity accepted"
  pass "main homes, valid identities, malformed bytes, and unsafe marker types"
}

test_clean_note() {
  local long cleaned
  [ "$(fm_parent_channel_clean_note $'a\tb\rc\nd')" = 'a b c d' ] || fail "line framing"
  [ -z "$(fm_parent_channel_clean_note '')" ] || fail "empty note"
  long=$(printf '%1300s' '' | tr ' ' x)
  cleaned=$(fm_parent_channel_clean_note "$long")
  [ "${#cleaned}" -eq 1200 ] || fail "note cap"
  [ "$cleaned" = "${long:0:1200}" ] || fail "note prefix"
  pass "notes fold control separators and retain a bounded prefix"
}

test_append() {
  local path="$TMP/nested/channel.status"
  fm_parent_channel_append_once "$path" 'done: task complete' || fail "create channel"
  fm_parent_channel_append_once "$path" 'done: task complete' || fail "retry append"
  [ "$(wc -l < "$path" | tr -d ' ')" = 1 ] || fail "duplicate event"
  fm_parent_channel_append_once "$path" 'failed: another task' || fail "distinct append"
  [ "$(cat "$path")" = $'done: task complete\nfailed: another task' ] || fail "event order"
  ln -s "$path" "$TMP/channel-link"
  fm_parent_channel_append_once "$TMP/channel-link" extra && fail "symlink append accepted"
  ln -s "$TMP/missing" "$TMP/dangling-link"
  fm_parent_channel_append_once "$TMP/dangling-link" extra && fail "dangling link accepted"
  fm_parent_channel_append_once "$TMP/nested" extra && fail "directory append accepted"
  [ ! -e "$TMP/missing" ] || fail "dangling target created"
  [ "$(wc -l < "$path" | tr -d ' ')" = 2 ] || fail "unsafe append changed channel"
  pass "append creates parents, preserves event order, deduplicates retries, and refuses unsafe destinations"
}

test_identity
test_clean_note
test_append
