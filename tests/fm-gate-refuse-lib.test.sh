#!/usr/bin/env bash
# Disposable lab markers and layout override restrictions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$ROOT/bin/fm-gate-refuse-lib.sh"

# Python owns the temporary fixture lifetime so cleanup is portable.
python3 - "$ROOT" <<'PY' || exit 1
import os
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='fm-gate-lab-test-') as directory:
    root = pathlib.Path(directory)
    for name in ('empty home', 'populated', 'hidden', 'invalid', 'directory-marker'):
        (root / name).mkdir()
    (root / 'populated' / 'keep').write_text('untouched\n')
    (root / 'hidden' / '.keep').write_text('hidden\n')
    (root / 'invalid' / '.fm-lab-home').write_text('fm-lab-home v10\n')
    (root / 'directory-marker' / '.fm-lab-home').mkdir()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('FM_')}
    result = subprocess.run(['bash', '-u', '-c', r'''
ROOT=$1
FIXTURE=$2
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
. "$ROOT/bin/fm-gate-refuse-lib.sh"
for home in '' "$FIXTURE/missing" "$FIXTURE/populated" "$FIXTURE/hidden"; do
  if fm_gate_lab_mark "$home"; then fail "marked invalid home [$home]"; fi
done
[ "$(cat "$FIXTURE/populated/keep")" = untouched ] || fail 'existing file changed'
[ ! -e "$FIXTURE/populated/.fm-lab-home" ] || fail 'populated home received marker'
[ ! -e "$FIXTURE/hidden/.fm-lab-home" ] || fail 'hidden content ignored'
got=$(fm_gate_lab_mark "$FIXTURE/empty home") || fail 'empty home rejected'
[ -z "$got" ] || fail 'marking printed output'
fm_gate_lab_home "$FIXTURE/empty home" || fail 'marked home not recognized'
if fm_gate_lab_mark "$FIXTURE/empty home"; then fail 'marked home still considered empty'; fi
pass 'marking accepts only empty directories and preserves existing content'
for home in '' "$FIXTURE/missing" "$FIXTURE/invalid" "$FIXTURE/directory-marker"; do
  if fm_gate_lab_home "$home"; then fail "accepted invalid marker [$home]"; fi
done
printf 'fm-lab-home v1\nadditional metadata\n' > "$FIXTURE/invalid/.fm-lab-home"
got=$(fm_gate_lab_home "$FIXTURE/invalid") || fail 'valid first line rejected'
[ -z "$got" ] || fail 'recognition printed output'
printf 'fm-lab-home v1 \n' > "$FIXTURE/invalid/.fm-lab-home"
if fm_gate_lab_home "$FIXTURE/invalid"; then fail 'trailing space accepted'; fi
pass 'recognition requires an exact first-line token in a regular file'
if fm_gate_lab_permitted; then fail 'unset home permitted'; fi
FM_HOME="$FIXTURE/empty home"
fm_gate_lab_permitted || fail 'stock layout refused'
FM_STATE_OVERRIDE=''
fm_gate_lab_permitted || fail 'empty override refused'
FM_CUSTOM_OVERRIDE="$FIXTURE/elsewhere"
if fm_gate_lab_permitted; then fail 'custom relocation permitted'; fi
unset FM_CUSTOM_OVERRIDE
FM_STATE_OVERRIDE=' '
if fm_gate_lab_permitted; then fail 'whitespace relocation permitted'; fi
unset FM_STATE_OVERRIDE
FM_OTHER_SETTING=enabled
export FM_OTHER_SETTING
fm_gate_lab_permitted || fail 'unrelated setting refused'
pass 'permission requires a marked home and rejects every nonempty layout override'
''', 'fm-gate-lab-test', sys.argv[1], directory], env=env, check=False)
    sys.exit(result.returncode)
PY


test_gate_environment_signals() (
  local value got rc
  unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE
  for value in '' 0 false 1; do
    NO_MISTAKES_GATE=$value
    export NO_MISTAKES_GATE
    FM_GATE_REFUSE_REASON=stale
    fm_is_gate_agent /nonexistent || fail "set marker rejected [$value]"
    [ "$FM_GATE_REFUSE_REASON" = env ] || fail 'environment reason missing'
    got=$(fm_is_gate_agent /nonexistent); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$got" ] || fail 'detection output or status'
  done
  FM_GATE_REFUSE_BYPASS=1
  got=$(fm_is_gate_agent /nonexistent); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'exact bypass did not suppress detection'
  for value in '' 0 true 01; do
    FM_GATE_REFUSE_BYPASS=$value
    fm_is_gate_agent /nonexistent || fail "non-bypass value suppressed detection [$value]"
  done
  unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
  got=$(fm_is_gate_agent /nonexistent); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'absent marker detected outside a checkout'
  pass 'any set gate marker detects silently and only exact bypass 1 suppresses it'
)

test_gate_refusal_exit() (
  local got rc
  unset FM_GATE_REFUSE_BYPASS FM_HOME
  NO_MISTAKES_GATE=''
  export NO_MISTAKES_GATE
  got=$(fm_refuse_if_gate_agent /nonexistent 2>&1; printf 'continued'); rc=$?
  [ "$rc" -eq 3 ] || fail 'refusal did not exit with code 3'
  [ "$got" = 'error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)' ] || fail 'refusal diagnostic or hard exit changed'
  FM_GATE_REFUSE_BYPASS=1
  got=$(fm_refuse_if_gate_agent /nonexistent 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$got" ] || fail 'bypass refused lifecycle'
  unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
  got=$(fm_refuse_if_gate_agent /nonexistent 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$got" ] || fail 'ordinary context refused lifecycle'
  pass 'gate refusal exits before continuation while bypass and ordinary calls remain silent'
)

test_gate_environment_signals || exit 1
test_gate_refusal_exit || exit 1
