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


test_watcher_main_wait_sibling_cadences() (
  local state line record whom expected age key
  set_mtime() {
    local epoch=$1 stamp
    if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
      touch -t "$stamp" "$2"
    else
      stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
      touch -t "$stamp" "$2"
    fi
  }
  state=$(fm_test_tmproot main-wait-siblings) || exit 1
  export FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=14400
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  wake() { :; }
  wake || fail "test wake must return without exiting"
  fm_wake_append() { printf '%s\n' "$*" >> "$state/alarms"; }
  fm_wake_append stale test:fm-waiter probe
  [ "$(cat "$state/alarms")" = 'stale test:fm-waiter probe' ] || fail "test wake recorder lost its arguments"
  key=test_fm-waiter
  for line in \
    "paused: waiting for main's go" \
    "paused: waiting on firstmate" \
    "paused: waiting for CI" \
    "paused: waiting for main's go until 2099-01-01T00:00Z"; do
    printf '%s\n' "$line" > "$state/waiter.status"
    expected=external
    status_paused_awaits_firstmate "$line" && expected=supervisor
    : > "$state/.waiting-resurfaced-$key"
    set_mtime "$(( $(date +%s) - 15000 ))" "$state/.waiting-resurfaced-$key"
    record=$(wedge_wait_evidence waiter) || fail "missing wait evidence: $line"
    whom=$(printf '%s' "$record" | cut -d "$(printf '\037')" -f3)
    [ "$whom" = "$expected" ] || fail "wrong dependency: $line"
    for age in 3500 3700; do
      set_mtime "$(( $(date +%s) - age ))" "$state/waiter.status"
      : > "$state/alarms"
      wedge_defer_wait test:fm-waiter "$state/since" working 600 "$record"
      if [ "$expected" = supervisor ] && [ "$age" -eq 3700 ]; then
        [ -s "$state/alarms" ] || fail "main wait initial alarm missing"
        grep -F 'waiting on main' "$state/alarms" >/dev/null || fail "wrong alarm dependency"
      else
        [ ! -s "$state/alarms" ] || fail "wait alarmed too early: $line"
      fi
      printf '1' > "$state/.waiting-resurfaced-$key"
      set_mtime "$(( $(date +%s) - age ))" "$state/.waiting-resurfaced-$key"
      set_mtime "$(( $(date +%s) - 15000 ))" "$state/waiter.status"
      : > "$state/alarms"
      wedge_defer_wait test:fm-waiter "$state/since" working 600 "$record"
      if [ "$expected" = supervisor ] && [ "$age" -eq 3700 ]; then
        [ -s "$state/alarms" ] || fail "main wait repeat alarm missing"
      else
        [ ! -s "$state/alarms" ] || fail "wait repeated too early: $line"
      fi
      printf declaration > "$state/.paused-resurfaced-$key"
      set_mtime "$(( $(date +%s) - age ))" "$state/.paused-resurfaced-$key"
      if stale_wait_throttled "$key" declaration "$line"; then
        [ "$expected" != supervisor ] || [ "$age" -lt 3600 ] || fail "main wait throttle exceeded hour"
      else
        [ "$expected" = supervisor ] && [ "$age" -ge 3600 ] || fail "wait throttle ended early"
      fi
      set_mtime "$(( $(date +%s) - 15000 ))" "$state/.waiting-resurfaced-$key"
    done
  done
  pass "watcher sibling paths classify and bound undated main waits hourly"
)

test_watcher_main_wait_sibling_cadences
