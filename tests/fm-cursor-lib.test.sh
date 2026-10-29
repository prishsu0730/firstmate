#!/usr/bin/env bash
# Pure Cursor model catalog parsing validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"

test_catalog_matches() {
  local catalog got rc model
  catalog=$'Available models:\n  sonnet-4.5  - Description\n\topus-4.1\t - Another description\nplain - Plain model\nplain - Duplicate'
  for model in sonnet-4.5 opus-4.1 plain; do
    got=$(printf '%s\n' "$catalog" | fm_cursor_catalog_has_model "$model"); rc=$?
    [ "$rc" -eq 0 ] || fail "catalog match: $model"
    [ -z "$got" ] || fail "catalog match is silent"
  done
  pass "catalog IDs match across whitespace, multiple rows, and duplicates"
}

test_catalog_rejections() {
  local catalog got rc model
  catalog=$'sonnet-4.5 - Alias opus\nopus\nother - sonnet\nUPPER - Description\njoined-Description'
  for model in sonnet opus other-model upper joined ''; do
    got=$(printf '%s\n' "$catalog" | fm_cursor_catalog_has_model "$model"); rc=$?
    [ "$rc" -eq 1 ] || fail "catalog rejection: [$model]"
    [ -z "$got" ] || fail "catalog rejection is silent"
  done
  got=$(printf '' | fm_cursor_catalog_has_model sonnet); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$got" ] || fail "empty catalog"
  pass "partial IDs, descriptions, case differences, and unstructured lines are rejected"
}

test_catalog_ansi_and_literals() {
  local catalog got rc model
  catalog=$'\033[1;32m  model.v1+[fast]\033[0m - Colored model\n\033[33msecond\033[0m - Description - extra separator'
  for model in 'model.v1+[fast]' second; do
    got=$(printf '%s' "$catalog" | fm_cursor_catalog_has_model "$model"); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$got" ] || fail "colored literal ID: $model"
  done
  got=$(printf '%s' "$catalog" | fm_cursor_catalog_has_model 'modelXv1fast'); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$got" ] || fail "model IDs are literal"
  pass "ANSI escapes are removed and punctuation is literal without a final newline"
}

test_bounded_output_invalid_paths() {
  local path got rc
  for path in '' /dev/null /dev/null/missing-cursor; do
    got=$(fm_cursor_bounded_output "$path" --help 2>&1); rc=$?
    [ "$rc" -eq 1 ] || fail "bounded output rejects invalid path: [$path]"
    [ -z "$got" ] || fail "bounded output invalid path is silent"
    got=$(fm_cursor_verify_executable "$path" 2>&1); rc=$?
    [ "$rc" -eq 1 ] || fail "verification rejects invalid path: [$path]"
    [ -z "$got" ] || fail "invalid executable verification is silent"
  done
  pass "empty, nonexecutable, and missing paths fail silently before probing"
}

test_catalog_matches
test_catalog_rejections
test_catalog_ansi_and_literals
test_bounded_output_invalid_paths
