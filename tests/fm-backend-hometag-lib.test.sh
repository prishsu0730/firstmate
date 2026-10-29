#!/usr/bin/env bash
# Home tags remain stable and distinguish resolved installation paths.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$ROOT/bin/fm-backend-hometag-lib.sh"

assert_tag() {
  local input=$1 expected=$2 got
  FM_ROOT=$input
  got=$(fm_backend_hometag)
  [ "$got" = "$expected" ] || fail "tag [$input]: [$got]"
}

test_primary_tag() {
  FM_HOME=/dev/null
  assert_tag / firstmate-8a5edab2
  assert_tag / firstmate-8a5edab2
  local got
  got=$(fm_backend_hometag; printf sentinel)
  [ "$got" = firstmate-8a5edab2sentinel ] || fail "stdout has no trailing newline"
  pass "primary tags are stable and have no trailing newline"
}

test_resolved_paths() {
  assert_tag /./ firstmate-8a5edab2
  assert_tag /tmp/.. firstmate-8a5edab2
  assert_tag / firstmate-8a5edab2
  pass "equivalent physical roots produce the same tag"
}

test_missing_root_fallback() {
  assert_tag /firstmate-hometag-test/missing firstmate-ea3abd91
  assert_tag /firstmate-hometag-test/other firstmate-ae777c93
  assert_tag /firstmate-hometag-test/missing firstmate-ea3abd91
  pass "unavailable roots retain stable distinct tags from their literal paths"
}

test_secondmate_markers() {
  if ! python3 - "$ROOT" <<'PYTHON'
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='fm-hometag-test-') as directory:
    marker = pathlib.Path(directory) / '.fm-secondmate-home'
    for content, expected in (
        (b'worker-7\n', '2ndmate-worker-7-8a5edab2'),
        (b' \tworker-\n7 \r\n', '2ndmate-worker-7-8a5edab2'),
        (b' \t\r\n', 'firstmate-8a5edab2'),
        (b'', 'firstmate-8a5edab2'),
    ):
        marker.write_bytes(content)
        result = subprocess.run(['bash', '-u', '-c', r'''
. "$1/bin/fm-backend-hometag-lib.sh"
FM_HOME=$2
FM_ROOT=/
fm_backend_hometag
''', 'bash', sys.argv[1], directory], capture_output=True)
        assert result.returncode == 0, result
        assert result.stdout == expected.encode(), result.stdout
        assert result.stderr == b'', result.stderr
PYTHON
  then
    fail "secondmate marker tags"
  fi
  pass "secondmate markers strip whitespace and empty markers use primary tags"
}

test_primary_tag
test_resolved_paths
test_missing_root_fallback
test_secondmate_markers
