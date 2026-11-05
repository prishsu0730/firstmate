#!/usr/bin/env bash
# Behavior tests for bin/fm-commit-address-check.sh, the pre-push check that
# catches commit messages addressing the operator. The check is driven through
# its executable against real git copies; the word list it applies is owned by
# bin/fm-commit-address-lib.sh and shared with bin/fm-pr-merge.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-commit-address-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-commit-address-check)

# make_repo <dir> <message>...: a repo whose main has one commit, then one
# branch commit per message.
make_repo() {
  local dir=$1 msg
  shift
  fm_git_init_commit "$dir"
  git -C "$dir" checkout -q -b work
  for msg in "$@"; do
    printf '%s\n' "$msg" >>"$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" -c user.name=T -c user.email=t@example.invalid commit -q -m "$msg"
  done
}

run_check() {  # <dir> [args...]
  local dir=$1
  shift
  (cd "$dir" && "$CHECK" "$@" 2>"$TMP_ROOT/stderr") 
}

test_direct_address_in_subject_is_caught() {
  local repo="$TMP_ROOT/subject" rc=0
  make_repo "$repo" 'docs: tell the captain what changed'
  run_check "$repo" || rc=$?
  [ "$rc" -eq 1 ] || fail "subject address exited $rc, want 1"
  assert_grep 'tell the captain' "$TMP_ROOT/stderr" "offending subject was not named"
  assert_grep 'local amend' "$TMP_ROOT/stderr" "no fix hint printed"
  pass "a direct address in a commit subject is caught"
}

test_direct_address_in_body_is_caught() {
  local repo="$TMP_ROOT/body" rc=0
  make_repo "$repo" $'fix: tidy wording\n\nCaptain, this is done.'
  run_check "$repo" || rc=$?
  [ "$rc" -eq 1 ] || fail "body address exited $rc, want 1"
  pass "a direct address in a commit body is caught"
}

test_exempt_tokens_and_clean_messages_pass() {
  local repo="$TMP_ROOT/clean" rc=0
  make_repo "$repo" 'fix(captain-hold): keep refusal' 'docs: update data/captain.md and captain_hold' 'feat: add the check'
  run_check "$repo" || rc=$?
  [ "$rc" -eq 0 ] || fail "clean messages exited $rc: $(cat "$TMP_ROOT/stderr")"
  pass "hyphen, path, and underscore tokens and clean messages pass"
}

test_only_commits_beyond_the_base_are_checked() {
  local repo="$TMP_ROOT/base" rc=0
  fm_git_init_commit "$repo"
  git -C "$repo" -c user.name=T -c user.email=t@example.invalid commit -q --allow-empty -m 'old: captain was here'
  git -C "$repo" checkout -q -b work
  git -C "$repo" -c user.name=T -c user.email=t@example.invalid commit -q --allow-empty -m 'feat: fine'
  run_check "$repo" main || rc=$?
  [ "$rc" -eq 0 ] || fail "commit already on the base was checked (exit $rc)"
  pass "commits already on the base are not checked"
}

test_amend_clears_the_failure() {
  local repo="$TMP_ROOT/amend" rc=0
  make_repo "$repo" 'docs: captain note'
  run_check "$repo" || rc=$?
  [ "$rc" -eq 1 ] || fail "setup: want exit 1, got $rc"
  git -C "$repo" -c user.name=T -c user.email=t@example.invalid commit -q --amend -m 'docs: operator note'
  rc=0
  run_check "$repo" || rc=$?
  [ "$rc" -eq 0 ] || fail "amended message still failed (exit $rc)"
  pass "a local amend clears the failure"
}

test_unreadable_range_is_not_a_pass() {
  local repo="$TMP_ROOT/unreadable" rc=0
  make_repo "$repo" 'feat: fine'
  run_check "$repo" no-such-ref || rc=$?
  [ "$rc" -eq 2 ] || fail "unresolvable base exited $rc, want 2"
  rc=0
  (cd "$TMP_ROOT" && "$CHECK" 2>/dev/null) || rc=$?
  [ "$rc" -eq 2 ] || fail "non-git directory exited $rc, want 2"
  pass "an unreadable range or non-git copy refuses with exit 2"
}

test_direct_address_in_subject_is_caught
test_direct_address_in_body_is_caught
test_exempt_tokens_and_clean_messages_pass
test_only_commits_beyond_the_base_are_checked
test_amend_clears_the_failure
test_unreadable_range_is_not_a_pass

echo "# all fm-commit-address-check tests passed"
