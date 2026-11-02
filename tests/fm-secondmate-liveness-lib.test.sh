#!/usr/bin/env bash
# Pure secondmate relaunch-ledger boundaries without backend probes or launches.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_HOME="$TMP/home"
STATE="$TMP/records"
mkdir -p "$STATE"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$ROOT/bin/fm-secondmate-liveness-lib.sh"

# Fix the clock so the inclusive cutoff can be tested without timing races.
date() { printf '10000\n'; }

test_recent_attempts() {
  local ledger="$STATE/.secondmate-relaunch-mate"
  [ "$(fm_secondmate_liveness_recent_attempts absent 100)" = 0 ] || fail 'absent ledger count'
  [ ! -e "$STATE/.secondmate-relaunch-absent" ] || fail 'read created ledger'
  printf '9899\tattempt\n9900\tattempt\n9999\tattempt\n10000\trearmed\n10000\trelaunched\n10000\tfailed\nbad\tattempt\n-1\tattempt\n10000\tattempted\n' > "$ledger"
  [ "$(fm_secondmate_liveness_recent_attempts mate 100)" = 2 ] || fail 'inclusive cutoff or event filtering'
  [ "$(fm_secondmate_liveness_recent_attempts mate 0)" = 0 ] || fail 'zero window'
  [ "$(fm_secondmate_liveness_recent_attempts mate 101)" = 3 ] || fail 'expanded window'
  pass 'rolling counts include cutoff attempts, ignore malformed and outcome rows, and survive rearming'
}

test_append_and_unreadable() {
  local ledger="$STATE/.secondmate-relaunch-new" before
  fm_secondmate_liveness_ledger_add new attempt || fail 'append attempt'
  fm_secondmate_liveness_ledger_add new rearmed || fail 'append outcome'
  [ "$(cat "$ledger")" = "$(printf '10000\tattempt\n10000\trearmed')" ] || fail 'ledger framing or append preservation'
  before=$(cat "$ledger")
  [ "$(fm_secondmate_liveness_recent_attempts new 100)" = 1 ] || fail 'appended count'
  [ "$(cat "$ledger")" = "$before" ] || fail 'count mutated ledger'
  ln -s "$TMP/missing" "$STATE/.secondmate-relaunch-broken"
  if fm_secondmate_liveness_recent_attempts broken 100 > "$TMP/out"; then
    fail 'dangling ledger was counted as absent'
  fi
  pass 'ledger appends preserve history and broken ledger links fail closed'
}

test_early_probe_gates() {
  local meta="$TMP/empty.meta"
  : > "$meta"
  FM_SM_LIVE_CAUSE=stale FM_SM_LIVE_KILL=1 FM_SM_LIVE_STOPPED=1
  fm_secondmate_liveness_probe "$meta" mate poll || fail 'empty endpoint probe'
  [ "$FM_SM_LIVE_STATUS:$FM_SM_LIVE_STATE:$FM_SM_LIVE_KILL:$FM_SM_LIVE_STOPPED:$FM_SM_LIVE_CAUSE" = 'silent:unknown:0:0:' ] || fail 'empty probe did not reset outputs'
  ln -s "$TMP/missing" "$STATE/.secondmate-stopped-mate"
  fm_secondmate_liveness_probe "$TMP/nonexistent.meta" mate full || fail 'stopped probe'
  [ "$FM_SM_LIVE_STATUS:$FM_SM_LIVE_STOPPED:$FM_SM_LIVE_KILL" = 'skipped:1:0' ] || fail 'stop marker ignored'
  [ "$FM_SM_LIVE_REASON" = 'deliberately stopped; use fm-control relaunch to resume' ] || fail 'stop reason'
  [ ! -e "$FM_HOME" ] || fail 'read-only probes created operational home'
  pass 'empty endpoints reset outputs and dangling deliberate-stop markers take precedence over metadata'
}

test_recent_attempts
test_append_and_unreadable
test_early_probe_gates
