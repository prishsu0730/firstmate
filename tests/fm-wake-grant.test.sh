#!/usr/bin/env bash
# Grant publication sequencing without a supervision host.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-wake-grant.sh" "$TMP/fm-wake-grant.sh"
export GRANT_FIXTURE="$TMP"
mkdir "$TMP/records"
cat > "$TMP/fm-wake-lib.sh" <<'STUB'
STATE="$GRANT_FIXTURE/records"
FM_WAKE_QUEUE_LOCK="$STATE/lock"
FM_WAKE_QUEUE="$STATE/queue"
fm_lock_acquire_wait() { :; }
fm_lock_release() { :; }
fm_wake_grant_rows_valid() {
  [ -s "$1" ] && ! LC_ALL=C grep -q '[^0-9]' "$1"
}
fm_wake_branch_owner_matches() {
  [ "${3:-}" = generation-1 ] && [ -f "$1" ]
}
_fm_atomic_replace() { mv "$1" "$2"; }
STUB
printf 'owner\n' > "$TMP/records/.branch-eligible-owner"
printf 'signal\t7\talpha\tready\tdetail\nsignal\t8\tbeta\tready\tdetail\n' > "$TMP/records/queue"
grant() { bash "$TMP/fm-wake-grant.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"; }
expect_status() {
  local expected=$1 rc
  shift
  grant "$@"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc"
}

test_refusals() {
  expect_status 2
  expect_status 2 activate 1 generation-1
  expect_status 2 activate abc generation-1
  expect_status 2 publish generation-1
  expect_status 2 publish 'bad generation' 7
  expect_status 2 publish generation-1 invalid
  expect_status 1 publish stale 7
  expect_status 1 publish generation-1 9
  [ ! -e "$TMP/records/.branch-eligible-rows" ] || fail 'refusal published rows'
  pass 'invalid arguments, stale ownership and absent sequences refuse publication'
}

test_publication() {
  local rows="$TMP/records/.branch-eligible-rows"
  expect_status 0 publish generation-1 7 8
  [ "$(cat "$rows")" = "$(printf '7\n8')" ] || fail 'published rows'
  [ "$(stat -f '%Lp' "$rows" 2>/dev/null || stat -c '%a' "$rows")" = 600 ] || fail 'row permissions'
  expect_status 0 publish generation-1 7 8
  expect_status 1 publish generation-1 8
  [ "$(cat "$rows")" = "$(printf '7\n8')" ] || fail 'changed existing grant'
  expect_status 0 release generation-1
  printf '7\n' > "$TMP/records/.main-eligible-rows"
  expect_status 3 publish generation-1 7
  [ ! -e "$rows" ] || fail 'published main-owned row'
  expect_status 0 publish generation-1 8
  pass 'publication is private, repeatable, immutable and excludes main-owned sequences'
}

test_retirement() {
  expect_status 1 release stale
  [ -e "$TMP/records/.branch-eligible-rows" ] || fail 'stale release removed grant'
  expect_status 0 release generation-1
  expect_status 0 release generation-1
  [ -e "$TMP/records/.branch-eligible-owner" ] || fail 'release removed owner'
  expect_status 0 deactivate 123 generation-1
  [ ! -e "$TMP/records/.branch-eligible-owner" ] || fail 'deactivate retained owner'
  [ -z "$(find "$TMP/records" -name '*.tmp.*' -print)" ] || fail 'temporary files retained'
  pass 'release preserves ownership and deactivation retires it without temporary files'
}

test_refusals
test_publication
test_retirement
