#!/usr/bin/env bash
# Supervisor discovery with incomplete environments and independent overrides.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$ROOT/bin/fm-supervisor-target-lib.sh"

unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION

assert_fallback() {
  local got rc
  got=$(discover_supervisor_target); rc=$?
  [ "$rc" -eq 1 ] && [ "$got" = firstmate:0 ] || fail "target fallback: $rc [$got]"
  got=$(discover_supervisor_backend); rc=$?
  [ "$rc" -eq 1 ] && [ "$got" = tmux ] || fail "backend fallback: $rc [$got]"
}

test_incomplete_environments() {
  assert_fallback
  HERDR_ENV=1
  assert_fallback
  HERDR_ENV=0 HERDR_PANE_ID=pane
  assert_fallback
  HERDR_ENV=true
  assert_fallback
  HERDR_ENV='' HERDR_PANE_ID=pane
  assert_fallback
  pass "herdr requires both its exact environment marker and a pane"
}

test_independent_overrides() {
  local got
  FM_SUPERVISOR_TARGET='custom target' FM_SUPERVISOR_BACKEND='' TMUX_PANE='%7'
  got=$(discover_supervisor_target) || fail "explicit target status"
  [ "$got" = 'custom target' ] || fail "explicit target preserved"
  got=$(discover_supervisor_backend) || fail "detected backend status"
  [ "$got" = tmux ] || fail "target override does not choose backend"
  FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND=custom TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=pane HERDR_SESSION=isolated
  got=$(discover_supervisor_target) || fail "detected target status"
  [ "$got" = isolated:pane ] || fail "backend override does not choose target"
  got=$(discover_supervisor_backend) || fail "explicit backend status"
  [ "$got" = custom ] || fail "explicit backend preserved"
  pass "target and backend overrides resolve independently"
}

test_output_bytes() {
  local got
  FM_SUPERVISOR_TARGET=chosen FM_SUPERVISOR_BACKEND=chosen
  got=$(discover_supervisor_target; printf sentinel)
  [ "$got" = chosensentinel ] || fail "target has no trailing newline"
  got=$(discover_supervisor_backend; printf sentinel)
  [ "$got" = chosensentinel ] || fail "backend has no trailing newline"
  pass "discovery emits no trailing newline"
}

test_incomplete_environments
test_independent_overrides
test_output_bytes
