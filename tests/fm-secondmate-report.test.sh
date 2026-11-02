#!/usr/bin/env bash
# Correlated reports resolve seeded parent channels without remote services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
CORR=abcdef0123456789
mkdir -p "$TMP/local" "$TMP/remote" "$TMP/unseeded"
for home in local remote; do
  printf 'mate\n' > "$TMP/$home/.fm-secondmate-home"
done
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP/parent home" > "$TMP/local/.fm-secondmate-parent"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=unused\n' > "$TMP/remote/.fm-secondmate-parent"

report() {
  FM_HOME="$TMP/$1" FM_STATE_OVERRIDE="$TMP/outbound" bash "$ROOT/bin/fm-secondmate-report.sh" "${@:2}"
}

expect_failure() {
  local expected=$1 rc
  shift
  report "$@" > "$TMP/stdout" 2> "$TMP/stderr"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "refusal status: $rc instead of $expected"
  [ ! -s "$TMP/stdout" ] || fail "unexpected refusal stdout"
  [ -s "$TMP/stderr" ] || fail "missing refusal diagnostic"
}

assert_line() {
  local path=$1 number=$2 expected=$3 line epoch prefix
  line=$(sed -n "${number}p" "$path")
  prefix=${line%%' [at='*}
  epoch=${line#*' [at='}
  epoch=${epoch%%']:'*}
  case "$epoch" in ''|*[!0-9]*) fail "missing numeric timestamp" ;; esac
  [ "$prefix: ${line#*']: '}" = "$expected" ] || fail "report content: $line"
}

test_local() {
  report local "done" "$CORR" audit clean || fail "local report"
  assert_line "$TMP/parent home/state/mate.status" 1 "done [corr=$CORR]: audit clean (via-helper)"
  report local working "corr=$CORR" 'still running' || fail "prefixed correlation"
  assert_line "$TMP/parent home/state/mate.status" 2 "working [corr=$CORR]: still running (via-helper)"
  [ ! -e "$TMP/outbound" ] || fail "local report used override destination"
  pass "local reports create the parent directory, stamp lines, and normalize correlation prefixes"
}

test_documents() {
  report remote --doc "done" "$CORR" 'data/report name.md' see report || fail "document note"
  assert_line "$TMP/outbound/parent-replies.status" 1 "done [corr=$CORR]: see report (data/report name.md via-helper)"
  report remote --doc "done" "$CORR" data/report.md || fail "document without note"
  assert_line "$TMP/outbound/parent-replies.status" 2 "done [corr=$CORR]: data/report.md (via-helper)"
  report remote "done" ABCDEF0123456789 complete || fail "uppercase correlation"
  assert_line "$TMP/outbound/parent-replies.status" 3 'done [corr=ABCDEF0123456789]: complete (via-helper)'
  pass "remote reports use the state override and preserve document paths and optional notes"
}

test_refusals() {
  local corr
  expect_failure 2 local
  expect_failure 2 local "done" "$CORR"
  expect_failure 2 local "done" "$CORR" ''
  expect_failure 2 local --doc "done" "$CORR" ''
  for corr in short abcdef01234567890 abcdef012345678g; do
    expect_failure 1 local "done" "$corr" note
  done
  expect_failure 1 unseeded "done" "$CORR" note
  FM_HOME='' FM_STATE_OVERRIDE="$TMP/outbound" bash "$ROOT/bin/fm-secondmate-report.sh" "done" "$CORR" note > "$TMP/stdout" 2> "$TMP/stderr"
  [ "$?" -eq 1 ] || fail "missing home accepted"
  [ "$(wc -l < "$TMP/parent home/state/mate.status" | tr -d ' ')" = 2 ] || fail "refusal changed local channel"
  [ "$(wc -l < "$TMP/outbound/parent-replies.status" | tr -d ' ')" = 3 ] || fail "refusal changed remote channel"
  pass "missing arguments, malformed correlations, and unseeded or missing homes refuse without reports"
}

test_local
test_documents
test_refusals
