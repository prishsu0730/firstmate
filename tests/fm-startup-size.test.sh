#!/usr/bin/env bash
# tests/fm-startup-size.test.sh - behavior tests for bin/fm-startup-size.sh, the
# read-only command that prints the start-up size of a new chat.
#
# Coverage:
#   - the three lines (digest, AGENTS.md, total) and their exact AGENTS.md counts
#   - the total is the sum of the two parts
#   - it never takes the session lock and leaves state/ byte-for-byte unchanged
#   - the count-plus-newest-five OPEN DECISIONS view measures smaller than the
#     full listing once more than five decisions are open
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_SESSION_START_STAGE_FILE

SIZE="$ROOT/bin/fm-startup-size.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-startup-size-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

# new_world <name>: throwaway root with a known AGENTS.md plus an empty home.
new_world() {
  local name=$1 w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config" "$w/fakebin"
  git init -q -b main "$w/root"
  git -C "$w/root" commit -q --allow-empty -m init
  printf 'one two three\nfour five\n' > "$w/root/AGENTS.md"
  printf '%s\n' "$w"
}

run_size() {  # <world> [args...]
  local w=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/root" PATH="$BASE_PATH" "$SIZE" "$@"
}

num() {  # <line> <field>: the number before "<field>" on a size line
  printf '%s\n' "$1" | sed -n "s/.*[: ]\([0-9][0-9]*\) $2.*/\1/p" | head -1
}

test_prints_three_lines_and_sums() {
  local w out d_line a_line t_line
  w=$(new_world three-lines)
  out=$(run_size "$w") || fail "size command failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" -eq 3 ] || fail "expected exactly three lines: $out"
  d_line=$(printf '%s\n' "$out" | sed -n '1p')
  a_line=$(printf '%s\n' "$out" | sed -n '2p')
  t_line=$(printf '%s\n' "$out" | sed -n '3p')
  case "$d_line" in 'digest: '*' bytes, '*' words') ;; *) fail "bad digest line: $d_line" ;; esac
  [ "$a_line" = "AGENTS.md: 24 bytes, 5 words" ] || fail "bad AGENTS.md line: $a_line"
  [ "$(num "$t_line" bytes,)" -eq $(( $(num "$d_line" bytes,) + 24 )) ] || fail "total bytes is not the sum: $out"
  [ "$(num "$t_line" words)" -eq $(( $(num "$d_line" words) + 5 )) ] || fail "total words is not the sum: $out"
  pass "prints digest, AGENTS.md, and total lines that add up"
}

test_read_only_no_lock_no_state_change() {
  local w before after
  w=$(new_world read-only)
  printf 'needs-decision [key=a]: pick one\n' > "$w/home/state/t1.status"
  before=$(cd "$w/home" && find . -type f -exec cksum {} + | sort)
  run_size "$w" >/dev/null || fail "size command failed"
  after=$(cd "$w/home" && find . -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ] || fail "state changed:
$before
--
$after"
  [ ! -e "$w/home/state/.lock" ] || fail "the size command took the session lock"
  [ ! -e "$w/home/state/.session-start-complete" ] || fail "the size command wrote a completion record"
  pass "never takes the lock and leaves the home unchanged"
}

test_digest_view_is_smaller_than_full_listing() {
  local w i full short
  w=$(new_world smaller)
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf 'needs-decision [key=k%s] [at=%s]: a fairly long open question number %s that the full listing prints in whole\n' \
      "$i" "$((1700000000 + i))" "$i" > "$w/home/state/task$i.status"
  done
  full=$(num "$(run_size "$w" --full-open-decisions | sed -n 1p)" bytes,)
  short=$(num "$(run_size "$w" | sed -n 1p)" bytes,)
  [ -n "$full" ] && [ -n "$short" ] || fail "could not read the byte counts"
  [ "$short" -lt "$full" ] || fail "digest view ($short) is not smaller than the full listing ($full)"
  pass "the count-plus-five view measures smaller than the full listing"
}

test_rejects_unknown_argument() {
  local w
  w=$(new_world bad-arg)
  if run_size "$w" --nope >/dev/null 2>&1; then fail "accepted an unknown argument"; fi
  pass "rejects an unknown argument"
}

test_prints_three_lines_and_sums
test_read_only_no_lock_no_state_change
test_digest_view_is_smaller_than_full_listing
test_rejects_unknown_argument

echo "# fm-startup-size.test.sh: all assertions passed"
