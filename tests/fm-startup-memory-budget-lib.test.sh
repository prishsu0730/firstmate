#!/usr/bin/env bash
# Pure startup-memory estimate and decimal comparison validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$ROOT/bin/fm-startup-memory-budget-lib.sh"

assert_estimate() {
  local bytes=$1 expected=$2 got rc
  got=$(fm_startup_memory_estimated_tokens_for_bytes "$bytes"); rc=$?
  [ "$rc" -eq 0 ] || fail "estimate status for $bytes"
  [ "$got" = "$expected" ] || fail "estimate for $bytes: expected $expected, got $got"
}

test_estimates() {
  assert_estimate 0 0
  assert_estimate 1 1
  assert_estimate 2 1
  assert_estimate 3 1
  assert_estimate 4 2
  assert_estimate 5 2
  assert_estimate 6 2
  assert_estimate 22500 7500
  assert_estimate 22501 7501
  pass "byte estimates round upward at each three-byte boundary"
}

test_decimal_comparison() {
  local got
  fm_startup_memory_decimal_le 0 0 || fail "zero equality"
  fm_startup_memory_decimal_le 9 10 || fail "shorter decimal"
  fm_startup_memory_decimal_le 123 124 || fail "same-length ordering"
  fm_startup_memory_decimal_le 999999999999999999999999999999 1000000000000000000000000000000 || fail "large shorter decimal"
  fm_startup_memory_decimal_le 999999999999999999999999999998 999999999999999999999999999999 || fail "large same-length ordering"
  fm_startup_memory_decimal_le 999999999999999999999999999999 999999999999999999999999999999 || fail "large equality"
  if fm_startup_memory_decimal_le 10 9; then fail "longer decimal accepted"; fi
  if fm_startup_memory_decimal_le 124 123; then fail "larger same-length decimal accepted"; fi
  got=$(fm_startup_memory_decimal_le 1 2; printf sentinel)
  [ "$got" = sentinel ] || fail "comparison emitted output"
  pass "normalized decimals compare silently without arithmetic overflow"
}

test_invalid_and_output() {
  local value got rc
  for value in '' -1 +1 1.5 ' 1' '1 ' abc; do
    got=$(fm_startup_memory_estimated_tokens_for_bytes "$value"); rc=$?
    [ "$rc" -ne 0 ] && [ -z "$got" ] || fail "invalid byte count: $value"
    if fm_startup_memory_decimal_le "$value" 1; then fail "invalid left decimal: $value"; fi
    if fm_startup_memory_decimal_le 1 "$value"; then fail "invalid right decimal: $value"; fi
  done
  got=$(fm_startup_memory_estimated_tokens_for_bytes 4; printf sentinel)
  [ "$got" = $'2\nsentinel' ] || fail "estimate output newline"
  pass "invalid input is rejected and estimates have one final newline"
}

test_config_directory_guards() {
  local path got rc
  got=$(fm_startup_memory_budget_config_dir_safe "$ROOT" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$got" ] || fail "ordinary directory rejected or emitted output"
  for path in '' "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$ROOT/bin/fm-startup-memory-budget-lib.sh/missing"; do
    FM_STARTUP_MEMORY_BUDGET_ERROR=stale
    if fm_startup_memory_budget_config_dir_safe "$path"; then
      fail "invalid config directory accepted: $path"
    fi
    [ "$FM_STARTUP_MEMORY_BUDGET_ERROR" = 'config directory is not a directory' ] || fail "directory error not replaced: $path"
    got=$(fm_startup_memory_budget_config_dir_safe "$path" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail "invalid directory status or output: $path"
  done
  pass "directory guards accept directories and silently reject empty, regular-file and missing paths"
}

test_estimates
test_decimal_comparison
test_invalid_and_output
test_config_directory_guards
