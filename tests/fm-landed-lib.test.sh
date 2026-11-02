#!/usr/bin/env bash
# Pure Recently Landed selection validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-landed-lib.sh
. "$ROOT/bin/fm-landed-lib.sh"

test_deliveries() {
  local got
  got=$(jq -cn "${FM_LANDED_JQ_DEFS}"'
    [
      {kind:"ship", completion:{verb:"merged"}, pr_url:"https://example.test/pr/1"},
      {completion:{verb:"done"}, local_note:"local main"},
      {kind:"scout", report_path:"report.md", pr_url:"unrelated"}
    ] | map(. + {state:"done", structured:true})
    | map([landed_record, landed_artifact])') || fail "delivery evaluation"
  [ "$got" = '[[true,"https://example.test/pr/1"],[true,"local main"],[true,"report.md"]]' ] || fail "delivered artifacts"
  pass "merged PRs, local completions, and scout reports select their delivery artifacts"
}

test_exclusions() {
  local got
  got=$(jq -cn "${FM_LANDED_JQ_DEFS}"'
    [
      {kind:"captain", completion:{verb:"merged"}, pr_url:"pr"},
      {hold_kind:"captain", completion:{verb:"done"}, local_note:"local"},
      {kind:"scout", completion:{verb:"merged"}, pr_url:"pr"},
      {completion:{verb:"reported"}, report_path:"report.md"},
      {completion:{verb:"done"}, pr_url:"pr"},
      {state:"active"},
      {structured:false}
    ] | map({state:"done", structured:true} + .)
    | map(landed_record)') || fail "exclusion evaluation"
  [ "$got" = '[false,false,false,false,false,false,false]' ] || fail "excluded rows"
  pass "captain provenance, reportless scouts, mismatched artifacts, and unfinished rows are excluded"
}

test_compatibility() {
  local got
  got=$(jq -cn "${FM_LANDED_JQ_DEFS}"'
    [
      {state:"done", structured:true},
      {state:"done", structured:true, kind:"ship", pr_url:null, report_path:null, local_note:null},
      {state:"done", structured:true, kind:"scout"},
      {state:"done", structured:true, hold_kind:"captain"}
    ] | map(landed_record)') || fail "legacy selection evaluation"
  [ "$got" = '[true,true,false,false]' ] || fail "legacy selection"
  got=$(jq -cn "${FM_LANDED_JQ_DEFS}"'
    {completion:{verb:"reported"}, report_path:"cached/report.md"} | landed_artifact') || fail "cached artifact evaluation"
  [ "$got" = '"cached/report.md"' ] || fail "cached report artifact"
  pass "artifactless legacy rows retain selection and cached kindless reports retain display artifacts"
}

test_deliveries
test_exclusions
test_compatibility
