#!/usr/bin/env bash
# Primary-home marker validation without touching operational homes.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$ROOT/bin/fm-primary-scope-lib.sh"

# Python owns the temporary fixture lifetime so cleanup is portable.
python3 - "$ROOT" <<'PY'
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='fm-primary-scope-test-') as directory:
    base = pathlib.Path(directory)
    markers = {
        'valid': b'mate_01.example-name\n',
        'spaces': b' \t mate - 01 \r\n',
        'blank': b' \t\n',
        'empty': b'',
        'unterminated': b'mate-01',
        'slash': b'mate/01\n',
        'unicode': 'mate\u00e9\n'.encode(),
        'later': b'mate-01\ninvalid/second-line\n',
    }
    for name, content in markers.items():
        root = base / name
        root.mkdir()
        (root / '.fm-secondmate-home').write_bytes(content)
    for name in ('missing', 'directory', 'symlink'):
        (base / name).mkdir()
    (base / 'directory' / '.fm-secondmate-home').mkdir()
    (base / 'symlink' / '.fm-secondmate-home').symlink_to(
        base / 'valid' / '.fm-secondmate-home')
    for name in ('complete', 'no-agents', 'no-bin'):
        root = base / name
        root.mkdir()
        (root / '.fm-secondmate-home').write_text('mate-01\n')
        if name != 'no-agents':
            (root / 'AGENTS.md').touch()
        if name != 'no-bin':
            (root / 'bin').mkdir()
    (base / 'effective-state').mkdir()
    (base / 'state-file').touch()
    result = subprocess.run(['bash', '-u', '-c', r'''
ROOT=$1
FIXTURE=$2
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
. "$ROOT/bin/fm-primary-scope-lib.sh"
for name in valid spaces later; do
  fm_root_is_secondmate_home "$FIXTURE/$name" || fail "accepted marker [$name]"
done
pass 'valid first lines accept identifier punctuation and remove whitespace'
for name in blank empty unterminated slash unicode missing directory symlink; do
  if fm_root_is_secondmate_home "$FIXTURE/$name"; then
    fail "rejected marker [$name]"
  fi
done
pass 'invalid, unterminated, absent, directory and symlink markers are rejected'
fm_primary_root_matches "$FIXTURE/complete" || fail 'marked root without git'
for name in no-agents no-bin; do
  if fm_primary_root_matches "$FIXTURE/$name"; then fail "incomplete root [$name]"; fi
done
fm_primary_scope_matches "$FIXTURE/complete" "$FIXTURE/effective-state" || fail 'effective state directory'
for name in missing-state state-file; do
  if fm_primary_scope_matches "$FIXTURE/complete" "$FIXTURE/$name"; then
    fail "invalid effective state [$name]"
  fi
done
pass 'marked roots require project structure and scopes require an existing directory'
''', 'fm-primary-scope-test', sys.argv[1], str(base)], check=False)
    sys.exit(result.returncode)
PY
