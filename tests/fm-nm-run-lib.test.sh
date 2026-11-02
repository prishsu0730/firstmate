#!/usr/bin/env bash
# Run selection from complete overview tables without no-mistakes services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

assert_selection() {
  local expected=$1 branch=$2 overview=$3 actual
  actual=$(fm_nm_select_run "$branch" "$overview" /nonexistent)
  [ "$actual" = "$expected" ] || fail "selection: $actual instead of $expected"
}

test_precedence() {
  local overview
  overview='count: 3 of 3 total
runs[3]{id,branch,status,head,pr}:
  newest,topic,failed,abcdef0,
  older,topic,running,abcdef1,
  unrelated,other,running,abcdef2,'
  assert_selection 'selected|newest|failed|newest, older' topic "$overview"
  assert_selection 'selected|unrelated|running|unrelated' other "$overview"
  assert_selection absent missing "$overview"
  overview='count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  newest,topic,pending,abcdef0,
  older,topic,running,abcdef1,'
  assert_selection 'unknown|competing live runs; run ids: newest, older' topic "$overview"
  overview='count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  newest,topic,running,abcdef0,
  older,topic,cancelled,abcdef1,'
  assert_selection 'selected|newest|running|newest, older' topic "$overview"
  pass "newest failures remain authoritative and competing live runs are unknown"
}

test_structure() {
  local overview
  assert_selection unavailable topic 'CLI output without an overview'
  assert_selection absent topic 'count: 0 of 0 total
runs[0]{id,branch,status,head,pr}:'
  overview='count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  first,topic,completed,abcdef0,'
  assert_selection 'unknown|unreadable runs table; run ids: first' topic "$overview"
  overview='count: 1 of 1 total
count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  first,topic,completed,abcdef0,'
  assert_selection 'unknown|unreadable runs table; run ids: first' topic "$overview"
  overview='count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  first,topic,completed,abcdef0,
  broken,other,completed,abcdef1'
  assert_selection 'unknown|unreadable runs table; run ids: first' topic "$overview"
  pass "absent tables differ from empty tables and malformed structures retain readable ids"
}

test_semantics() {
  local overview
  overview='count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  first,"topic,with comma",completed,abcdef0,
  ignored,other,unrecognized,invalid,'
  assert_selection 'selected|first|completed|first' 'topic,with comma' "$overview"
  overview='count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  first,topic,mystery,abcdef0,'
  assert_selection 'unknown|unrecognized run status; run ids: first' topic "$overview"
  overview='count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  first,topic,completed,abcdef0,
  first,topic,failed,abcdef1,'
  assert_selection 'unknown|unreadable runs table; run ids: first' topic "$overview"
  overview='count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  first,topic,completed,short,'
  assert_selection 'unknown|unreadable runs table; run ids: first' topic "$overview"
  pass "quoted branch names match exactly and only target-branch semantics are validated"
}

test_precedence
test_structure
test_semantics
echo '# fm-nm-run-lib.test.sh: all assertions passed'
