#!/usr/bin/env bash
# Pathname component rules and command-substitution newline handling.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-path-lib.sh
. "$ROOT/bin/fm-path-lib.sh"

assert_components() {
  local path=$1 expected_dir=$2 expected_base=$3 got_dir got_base
  fm_dirname_to got_dir "$path"
  fm_basename_to got_base "$path"
  [ "$got_dir" = "$expected_dir" ] || fail "dirname for [$path]: [$got_dir]"
  [ "$got_base" = "$expected_base" ] || fail "basename for [$path]: [$got_base]"
}

test_empty_and_root_paths() {
  assert_components '' . ''
  assert_components / / /
  assert_components //// / /
  pass "empty paths and all-slash roots follow component rules"
}

test_relative_and_absolute_paths() {
  assert_components file . file
  assert_components ./file . file
  assert_components ../file .. file
  assert_components dir/sub/file dir/sub file
  assert_components /dir/sub/file /dir/sub file
  assert_components /file / file
  assert_components dir///file/// dir file
  assert_components /dir/// / dir
  assert_components . . .
  assert_components .. . ..
  pass "relative and absolute paths trim separators and retain dot components"
}

test_literal_text_and_newlines() {
  assert_components 'a b/*?[x]' 'a b' '*?[x]'
  assert_components '-dir/-file' '-dir' '-file'
  assert_components $'dir\nname/file\npart' $'dir\nname' $'file\npart'
  assert_components $'dir\n\n/file\n\n' dir file
  assert_components $'\n\n' . ''
  pass "literal shell characters survive and trailing result newlines are removed"
}

test_assignment_and_silent_output() {
  local result=stale output
  fm_dirname_to result /parent/child
  [ "$result" = /parent ] || fail "dirname replaces the caller's local variable"
  fm_basename_to result ''
  [ -z "$result" ] || fail "empty basename clears the previous result"
  output=$(
    fm_dirname_to result /parent/child
    fm_basename_to result /parent/child
    printf sentinel
  )
  [ "$output" = sentinel ] || fail "pathname assignments must not write stdout"
  pass "assignments replace caller variables, clear empty results, and remain silent"
}

test_empty_and_root_paths
test_relative_and_absolute_paths
test_literal_text_and_newlines
test_assignment_and_silent_output
