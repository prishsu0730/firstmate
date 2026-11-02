#!/usr/bin/env bash
# Lease record helpers without a supervision host or backend.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-lease-lib.sh
. "$ROOT/bin/fm-lease-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
STATE=$TMP

test_identity() {
  local value
  [ "$(unset FM_SUPERVISION_ACTOR; fm_lease_actor)" = main ] || fail "default actor"
  for value in main branch; do
    [ "$(FM_SUPERVISION_ACTOR=$value fm_lease_actor)" = "$value" ] || fail "actor $value"
  done
  FM_SUPERVISION_ACTOR=other fm_lease_actor > "$TMP/out" 2> "$TMP/err" && fail "unknown actor accepted"
  [ ! -s "$TMP/out" ] || fail "unknown actor produced output"
  for value in task.one task-two backlog A_9; do
    fm_lease_valid_id "$value" || fail "valid id $value"
  done
  for value in '' 'a/b' 'a b' $'a\nb'; do
    fm_lease_valid_id "$value" && fail "unsafe id accepted"
  done
  [ "$(fm_lease_path task.one)" = "$STATE/.lease-task.one" ] || fail "lease path"
  pass "actors and resource identifiers validate independently"
}

test_records() {
  fm_lease_read missing && fail "missing lease accepted"
  [ -z "$FM_LEASE_ACTOR$FM_LEASE_PID$FM_LEASE_EPOCH" ] || fail "missing fields"
  printf 'branch\t123\t456\n' > "$TMP/.lease-record"
  fm_lease_read record || fail "valid lease"
  [ "$FM_LEASE_ACTOR:$FM_LEASE_PID:$FM_LEASE_EPOCH" = branch:123:456 ] || fail "parsed fields"
  printf 'unknown\tbad\t789\n' > "$TMP/.lease-record"
  fm_lease_read record || fail "malformed lease should remain readable"
  [ -z "$FM_LEASE_ACTOR$FM_LEASE_PID" ] || fail "invalid fields retained"
  [ "$FM_LEASE_EPOCH" = 789 ] || fail "epoch lost"
  printf 'main\t123\t456' > "$TMP/.lease-record"
  fm_lease_read record || fail "unterminated lease"
  [ -z "$FM_LEASE_ACTOR$FM_LEASE_PID$FM_LEASE_EPOCH" ] || fail "unterminated record should read as stale"
  pass "lease reads reset fields and treat malformed records as stale"
}

test_liveness() {
  printf 'main\t%s\t1\n' "$$" > "$TMP/.lease-live"
  printf '%s\n' "$$" > "$TMP/.lock"
  fm_lease_live live || fail "current session lease not live"
  fm_lease_clear_stale live || fail "live cleanup"
  [ -f "$TMP/.lease-live" ] || fail "live lease removed"
  printf '1\n' > "$TMP/.lock"
  fm_lease_live live && fail "reserved lock pid accepted"
  printf 'invalid\n' > "$TMP/.lock"
  fm_lease_live live && fail "malformed lock accepted"
  fm_lease_clear_stale live || fail "stale cleanup"
  [ ! -e "$TMP/.lease-live" ] || fail "stale lease retained"
  fm_lease_clear_stale live || fail "repeat cleanup"
  fm_lease_read missing && fail "missing lease read"
  [ -z "$FM_LEASE_ACTOR$FM_LEASE_PID$FM_LEASE_EPOCH" ] || fail "missing read retained fields"
  pass "liveness requires the current session holder and stale cleanup preserves live leases"
}

test_identity
test_records
test_liveness
echo '# fm-lease-lib.test.sh: all assertions passed'
