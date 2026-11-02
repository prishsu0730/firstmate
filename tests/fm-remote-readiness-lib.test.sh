#!/usr/bin/env bash
# Remote readiness sequencing without network or runtime services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$ROOT/bin/fm-remote-readiness-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export READINESS_FIXTURE="$TMP"
cat > "$TMP/fm-on.sh" <<'STUB'
#!/usr/bin/env bash
set -u
n=$(cat "$READINESS_FIXTURE/count")
n=$((n + 1))
printf '%s\n' "$n" > "$READINESS_FIXTURE/count"
printf '%s\n' "$*" >> "$READINESS_FIXTURE/calls"
if IFS= read -r unexpected; then
  printf 'unexpected stdin: %s\n' "$unexpected" >&2
  exit 99
fi
printf 'stdout %s\n' "$n"
printf 'stderr %s\n' "$n" >&2
exit "$(sed -n "${n}p" "$READINESS_FIXTURE/results")"
STUB
chmod +x "$TMP/fm-on.sh"

check_sequence() {
  local expected_rc=$1 expected_count=$2 rc expected_calls
  shift 2
  printf '%s\n' "$@" > "$TMP/results"
  printf '0\n' > "$TMP/count"
  : > "$TMP/calls"
  FM_REMOTE_READINESS_OUT=stale
  fm_remote_readiness_ensure "$TMP" 'mate-one' <<< 'must not reach transport'
  rc=$?
  [ "$rc" -eq "$expected_rc" ] || fail "status for sequence $*: $rc"
  [ "$(cat "$TMP/count")" -eq "$expected_count" ] || fail "call count for sequence $*"
  [ "$FM_REMOTE_READINESS_OUT" = "$(printf 'stdout %s\nstderr %s' "$expected_count" "$expected_count")" ] || fail "last combined output for sequence $*"
  expected_calls='mate-one fm-remote-doctor.sh'
  if [ "$expected_count" -ge 2 ]; then
    expected_calls="$expected_calls
mate-one fm-remote-doctor.sh --fix"
  fi
  if [ "$expected_count" -eq 3 ]; then
    expected_calls="$expected_calls
mate-one fm-remote-doctor.sh"
  fi
  [ "$(cat "$TMP/calls")" = "$expected_calls" ] || fail "argument order for sequence $*"
}

test_ready() {
  check_sequence 0 1 0
  pass "ready host skips repair and preserves combined diagnostic output"
}

test_repair() {
  check_sequence 0 3 1 0 0
  check_sequence 0 3 2 7 0
  pass "every non-transport gap repairs and uses the final read-only verdict"
}

test_remaining_gap() {
  check_sequence 1 3 1 0 1
  check_sequence 1 3 1 0 42
  pass "successful repair cannot override a remaining gap and failures normalize to one"
}

test_transport_failure() {
  check_sequence 255 1 255
  check_sequence 255 2 1 255
  check_sequence 255 3 1 0 255
  pass "unknown transport completion stops immediately at each stage"
}

test_ready
test_repair
test_remaining_gap
test_transport_failure
