#!/usr/bin/env bash
# Pure merge-outcome request validation before publication.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$ROOT/bin/fm-merge-outcome-lib.sh"

assert_refusal() {
  local expected=$1 got rc
  shift
  got=$(
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_merge_outcome_report /dev/null /dev/null "$@"
    rc=$?
    [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = false ] || exit 99
    exit "$rc"
  ); rc=$?
  [ "$rc" -eq "$expected" ] && [ -z "$got" ] || fail "request refusal: [$*], status $rc"
}

test_origin_and_authority() {
  local value
  for value in '' SELF polling 'self '; do
    assert_refusal 2 task https://github.com/owner/repo/pull/1 "$value" attended
  done
  for value in unknown Away 'attended ' 'away grant'; do
    assert_refusal 2 task https://github.com/owner/repo/pull/1 self "$value"
  done
  pass 'invalid origins and authorities refuse silently and clear the deduplication result'
}

test_invalid_identity() {
  local value
  for value in '' ../task 'two tasks' /absolute; do
    assert_refusal 2 "$value" https://github.com/owner/repo/pull/1 self
  done
  for value in '' garbage https://github.com/owner/repo/issues/1; do
    assert_refusal 2 task "$value" poll
  done
  pass 'invalid task IDs and PR URLs refuse before accessing publication state'
}

test_unavailable_state() {
  local origin authority
  for origin in self poll; do
    for authority in '' attended away external yolo away-grant; do
      assert_refusal 1 task https://github.com/owner/repo/pull/1 "$origin" "$authority"
    done
  done
  pass 'accepted origins and current and legacy authorities require a state directory'
}

test_origin_and_authority
test_invalid_identity
test_unavailable_state
