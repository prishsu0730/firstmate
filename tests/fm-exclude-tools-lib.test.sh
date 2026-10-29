#!/usr/bin/env bash
# Tool exclusion parsing and launch checks without a live runtime.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$ROOT/bin/fm-exclude-tools-lib.sh"

# Python owns the temporary fixture lifetime so cleanup is portable.
python3 - "$ROOT" <<'PY'
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='fm-exclude-tools-test-') as directory:
    root = pathlib.Path(directory)
    fixtures = {
        'empty': b'  \n# comment\n\t # indented comment\r\n',
        'names': b'  read \r\nTool_2.name-x\nread',
        'comma': b'read,write\n',
        'space': b'read write\n',
        'inline': b'read # comment\n',
        'slash': b'../read\n',
    }
    for name, content in fixtures.items():
        folder = root / name
        folder.mkdir()
        (folder / 'crew-exclude-tools').write_bytes(content)
    (root / 'invalid').mkdir()
    (root / 'invalid' / 'crew-exclude-tools').mkdir()
    result = subprocess.run(['bash', '-u', '-c', r'''
ROOT=$1
FIXTURE=$2
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
. "$ROOT/bin/fm-exclude-tools-lib.sh"
assert_names() {
  local folder=$1 expected=$2 got
  got=$(fm_exclude_tools_names "$FIXTURE/$folder") || fail "parse [$folder] failed"
  [ "$got" = "$expected" ] || fail "names [$folder]: [$got]"
}
assert_names absent ''
assert_names empty ''
assert_names names 'read,Tool_2.name-x,read'
got=$(fm_exclude_tools_names "$FIXTURE/names"; printf sentinel)
[ "$got" = 'read,Tool_2.name-x,readsentinel' ] || fail 'names have no appended newline'
pass 'missing and comment-only lists are empty; names retain order and duplicates'
for folder in comma space inline slash invalid; do
  if got=$(fm_exclude_tools_names "$FIXTURE/$folder" 2>&1); then
    fail "invalid [$folder] accepted"
  fi
  case "$got" in
    *config/crew-exclude-tools*) ;;
    *) fail "invalid [$folder] error omits file" ;;
  esac
done
pass 'malformed names and nonregular files are refused'
for harness in pi pi-signed; do
  got=$(fm_exclude_tools_check "$harness" 0 "$FIXTURE/names") || fail "$harness refused"
  [ "$got" = 'read,Tool_2.name-x,read' ] || fail "$harness names changed"
done
for harness in pi pi-signed claude; do
  if got=$(fm_exclude_tools_check "$harness" 1 "$FIXTURE/names" 2>&1); then
    fail "raw $harness accepted exclusions"
  fi
  case "$got" in *'raw launch command'*) ;; *) fail 'raw refusal reason missing' ;; esac
done
if got=$(fm_exclude_tools_check claude 0 "$FIXTURE/names" 2>&1); then
  fail 'unsupported runtime accepted exclusions'
fi
case "$got" in *'claude runtime cannot hide tools'*) ;; *) fail 'runtime refusal reason missing' ;; esac
for raw in 0 1; do
  got=$(fm_exclude_tools_check claude "$raw" "$FIXTURE/empty") || fail 'empty exclusions refused'
  [ -z "$got" ] || fail 'empty exclusions printed names'
done
if fm_exclude_tools_check pi 0 "$FIXTURE/comma" >/dev/null 2>&1; then
  fail 'launch check accepted malformed names'
fi
pass 'supported runtimes return names; raw and unsupported launches refuse nonempty lists'
''', 'fm-exclude-tools-test', sys.argv[1], directory], check=False)
    sys.exit(result.returncode)
PY
