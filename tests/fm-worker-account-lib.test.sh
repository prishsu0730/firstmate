#!/usr/bin/env bash
# Worker account pin parsing without credentials or runtime services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
PIN="$TMP/pin"

expect_read() {
  local harness=$1 expected_status=$2 expected_output=$3 output rc
  output=$(fm_worker_account_read "$harness" "$PIN")
  rc=$?
  [ "$rc" -eq "$expected_status" ] || fail "read status for $harness: $rc instead of $expected_status"
  [ "$output" = "$expected_output" ] || fail "read output for $harness"
}

test_runner_files() {
  local harness output
  [ "$(fm_worker_account_file claude)" = claude-account ] || fail "Claude pin file"
  for harness in pi pi-signed; do
    [ "$(fm_worker_account_file "$harness")" = pi-account ] || fail "Pi pin file"
  done
  for harness in codex unknown ''; do
    output=$(fm_worker_account_file "$harness") && fail "unpinnable runner accepted"
    [ -z "$output" ] || fail "unpinnable runner output"
  done
  pass "pinnable runners map to their pin files and other runners refuse silently"
}

test_valid_pins() {
  local ending harness path
  # shellcheck disable=SC2016 # Pin paths must preserve shell expressions literally.
  path='/literal path/$TOKEN/$(command)/~'
  for ending in '' $'\n'; do
    printf '%s%s' ordinary "$ending" > "$PIN"
    expect_read claude 0 $'ordinary\t'
    printf '%s%s' "$path" "$ending" > "$PIN"
    expect_read claude 0 "$path"$'\t'
    for harness in pi pi-signed; do
      printf 'ordinary\nprovider-one  provider.two provider_3%s' "$ending" > "$PIN"
      expect_read "$harness" 0 $'ordinary\tprovider-one  provider.two provider_3'
      printf '%s\nprovider%s' "$path" "$ending" > "$PIN"
      expect_read "$harness" 0 "$path"$'\tprovider'
    done
  done
  pass "valid pins preserve literal paths and provider spacing with optional final newline"
}

test_invalid_pins() {
  local body
  expect_read claude 3 ''
  mkdir "$PIN"
  expect_read claude 5 ''
  rmdir "$PIN"
  # shellcheck disable=SC2088 # A literal tilde path is deliberately malformed.
  for body in '' relative '~/.claude' $'ordinary\n\n' $'ordinary\r\n' $'/path\tvalue' $'/path\177' $'ordinary\nprovider'; do
    printf '%s' "$body" > "$PIN"
    expect_read claude 6 ''
  done
  printf '/path\000hidden\n' > "$PIN"
  expect_read claude 6 ''
  for body in ordinary $'ordinary\n' $'ordinary\n provider' $'ordinary\nprovider ' $'ordinary\n-provider' $'ordinary\nprovider/name' $'ordinary\nprovider\tother' $'ordinary\nprovider\nextra' $'ordinary\nprovider\r\n'; do
    printf '%s' "$body" > "$PIN"
    expect_read pi 6 ''
    expect_read pi-signed 6 ''
  done
  printf 'ordinary\nprovider\000hidden\n' > "$PIN"
  expect_read pi 6 ''
  pass "missing and nonregular files and malformed bytes refuse with documented statuses"
}

test_model_provider() {
  local model output
  for model in provider/model provider/model/variant; do
    [ "$(fm_worker_account_pi_provider "$model")" = provider ] || fail "qualified model provider"
  done
  for model in '' model /model provider/ /; do
    output=$(fm_worker_account_pi_provider "$model") && fail "unqualified model accepted"
    [ -z "$output" ] || fail "unqualified model output"
  done
  pass "qualified models return the first component and incomplete models refuse silently"
}

test_runner_files
test_invalid_pins
test_valid_pins
test_model_provider
