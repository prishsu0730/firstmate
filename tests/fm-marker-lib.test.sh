#!/usr/bin/env bash
# Compatibility marker construction and recognition through the legacy entry point.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

test_marker_bytes() {
  local marked decoded parsed
  [ "$FM_INJECT_MARK" = $'\xE2\x81\xA3' ] || fail "invisible routing separator"
  fm_message_mark_from_firstmate $'hello\n世界\n' marked || fail "mark status"
  [ "$marked" = $'[fm-from-firstmate]\xE2\x81\xA3hello\n世界\n' ] || fail "exact carrier bytes"
  fm_message_from_firstmate "$marked" || fail "compatibility recognition"
  fm_operational_input_kind "$marked" parsed || fail "current kind status"
  [ "$parsed" = from-firstmate ] || fail "current kind"
  fm_operational_input_body "$marked" decoded || fail "body status"
  [ "$decoded" = $'hello\n世界\n' ] || fail "body preserves trailing newline"
  pass "legacy entry point constructs current byte-compatible carriers"
}

test_idempotence() {
  local once twice got rc
  fm_message_mark_from_firstmate payload once || fail "first marking"
  fm_message_mark_from_firstmate "$once" twice || fail "repeat marking"
  [ "$once" = "$twice" ] || fail "repeat marking is idempotent"
  got=$(fm_message_mark_from_firstmate payload once; printf sentinel)
  [ "$got" = sentinel ] || fail "marking emits no stdout"
  fm_message_mark_from_firstmate payload; rc=$?
  [ "$rc" -eq 2 ] || fail "missing result variable returns 2"
  pass "marking is idempotent, silent, and requires a result variable"
}

test_nonmatches() {
  local candidate generic
  for candidate in '' payload '[fm-from-firstmate]payload' "$FM_FROMFIRST_MARK" "prefix${FM_FROMFIRST_MARK}payload"; do
    if fm_message_from_firstmate "$candidate"; then
      fail "unmarked or empty carrier accepted: [$candidate]"
    fi
  done
  fm_operational_input_encode watcher payload generic || fail "generic encoding"
  if fm_message_from_firstmate "$generic"; then
    fail "generic operational input accepted as from-firstmate"
  fi
  pass "recognition requires a leading complete carrier and a nonempty body"
}

test_mark_nonmatches() {
  local candidate marked decoded
  for candidate in '[fm-from-firstmate]payload' "prefix${FM_FROMFIRST_MARK}payload"; do
    fm_message_mark_from_firstmate "$candidate" marked || fail "mark nonmatch status"
    [ "$marked" = "${FM_FROMFIRST_MARK}${candidate}" ] || fail "nonmatch receives complete leading marker"
    fm_message_from_firstmate "$marked" || fail "marked nonmatch is recognized"
    fm_operational_input_body "$marked" decoded || fail "marked nonmatch body status"
    [ "$decoded" = "$candidate" ] || fail "original marker-like text is preserved"
  done
  pass "incomplete and misplaced markers are wrapped without changing the original text"
}

test_marker_bytes
test_idempotence
test_nonmatches
test_mark_nonmatches
