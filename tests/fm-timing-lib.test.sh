#!/usr/bin/env bash
# Timing sanitization and disabled or malformed recording without files.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
FM_TIMING_DETAIL_MAX=80
# shellcheck source=bin/fm-timing-lib.sh
. "$ROOT/bin/fm-timing-lib.sh"

assert_sanitized() {
  local input=$1 expected=$2 got
  got=$(fm_timing_sanitize "$input")
  [ "$got" = "$expected" ] || fail "sanitize [$input]: [$got]"
}

test_identity_characters() {
  assert_sanitized '' ''
  assert_sanitized 'AZaz09._@:/+-' 'AZaz09._@:/+-'
  assert_sanitized 'host/path:22' 'host/path:22'
  assert_sanitized 'a=b$?[x]*' 'a_b___x__'
  pass "identity characters survive and punctuation is replaced"
}

test_whitespace_rejection() {
  assert_sanitized 'KEY=secret command' unrecordable
  assert_sanitized ' leading' unrecordable
  assert_sanitized 'trailing ' unrecordable
  assert_sanitized $'host\tname' unrecordable
  assert_sanitized $'host\nname' unrecordable
  assert_sanitized $'host\rname' unrecordable
  assert_sanitized $'host\vname' unrecordable
  assert_sanitized $'host\fname' unrecordable
  pass "any whitespace rejects the entire detail"
}

test_length_boundaries() {
  local line='' i got
  for ((i = 0; i < 80; i++)); do line+=x; done
  assert_sanitized "$line" "$line"
  assert_sanitized "${line}y" "$line"
  FM_TIMING_DETAIL_MAX=4
  assert_sanitized 'ab=def' 'ab_d'
  assert_sanitized 'abcd secret' unrecordable
  FM_TIMING_DETAIL_MAX=0
  assert_sanitized identity ''
  FM_TIMING_DETAIL_MAX=80
  got=$(fm_timing_sanitize host; printf sentinel)
  [ "$got" = $'host\nsentinel' ] || fail "stdout ends with one newline"
  pass "length caps apply after replacement and whitespace rejection precedes truncation"
}

test_recording_noops() {
  local got rc start
  unset FM_TIMING_LOG FM_TIMING_EPOCH_MS
  fm_timing_enabled; rc=$?
  [ "$rc" -eq 1 ] || fail "unset log disables timing"
  FM_TIMING_LOG=''
  fm_timing_enabled; rc=$?
  [ "$rc" -eq 1 ] || fail "empty log disables timing"
  got=$(fm_timing_record scope name 123; printf sentinel)
  [ "$got" = sentinel ] || fail "disabled recording is silent and succeeds"
  fm_timing_record scope name 123 || fail "disabled recording status"
  [ "${FM_TIMING_EPOCH_MS+x}" != x ] || fail "disabled recording leaves epoch unset"
  FM_TIMING_LOG=/dev/null
  fm_timing_enabled || fail "nonempty log enables timing"
  for start in '' invalid -1 1.5 '12 3'; do
    fm_timing_record scope name "$start" || fail "malformed start status [$start]"
    got=$(fm_timing_record scope name "$start"; printf sentinel)
    [ "$got" = sentinel ] || fail "malformed start is silent [$start]"
    [ "${FM_TIMING_EPOCH_MS+x}" != x ] || fail "malformed start leaves epoch unset [$start]"
  done
  unset FM_TIMING_LOG
  pass "disabled timing and malformed starts succeed silently without initializing an epoch"
}

test_identity_characters
test_whitespace_rejection
test_length_boundaries
test_recording_noops
