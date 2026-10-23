#!/usr/bin/env bash
# tests/fm-classify-main-wait.test.sh - a `paused:` line whose reason says it waits
# on main / firstmate is a wait on the supervisor, not the outside world, and is
# rechecked on the short FM_MAIN_WAIT_SECS cadence (bin/fm-classify-lib.sh owns
# status_paused_awaits_firstmate and status_pause_recheck_secs). Genuine external
# and dated waits keep the long pause cadence.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

test_main_wait_reasons_are_recognized() {
  local line
  for line in \
    "paused [at=1788576000]: waiting for main's go before starting no-mistakes" \
    "paused: waiting on main" \
    "paused: waiting main review" \
    "paused: ready, main's go needed" \
    "paused: waiting for firstmate" \
    "paused: Waiting On Firstmate's answer"; do
    status_paused_awaits_firstmate "$line" || fail "not read as a wait on main: $line"
  done
  pass "main-wait wording is read as a wait on main"
}

test_external_and_dated_waits_are_not_main_waits() {
  local line
  for line in \
    "paused: waiting for CI to finish" \
    "paused: waiting for the forge to recover" \
    "paused: waiting for mainline CI" \
    "paused: waiting for maintainers" \
    "paused: waiting for main's go until 2099-01-01T00:00Z" \
    "working: waiting for main's go" \
    "blocked: waiting for main" \
    "captain-held: waiting on main"; do
    ! status_paused_awaits_firstmate "$line" || fail "wrongly read as a wait on main: $line"
  done
  pass "external, dated, and non-pause lines are not main waits"
}

test_recheck_cadence() {
  local main_line='paused: waiting for main'
  local ext_line='paused: waiting for CI'
  [ "$(status_pause_recheck_secs "$main_line" 14400)" = 3600 ] || fail "main wait did not get the hour cadence"
  [ "$(status_pause_recheck_secs "$ext_line" 14400)" = 14400 ] || fail "external wait lost the long cadence"
  [ "$(status_pause_recheck_secs "$main_line" 900)" = 900 ] || fail "main cadence exceeded the pause cadence"
  pass "main wait rechecks hourly, external waits keep the long cadence"
}

test_main_wait_reasons_are_recognized
test_external_and_dated_waits_are_not_main_waits
test_recheck_cadence
