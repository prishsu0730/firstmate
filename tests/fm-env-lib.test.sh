#!/usr/bin/env bash
# Environment value parsing without reading the home's environment file.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-env-lib.sh
. "$ROOT/bin/fm-env-lib.sh"

# Python owns the temporary fixture lifetime so cleanup is portable.
python3 - "$ROOT" <<'PY'
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='fm-env-test-') as directory:
    fixture = pathlib.Path(directory) / 'fixture'
    fixture.write_bytes(b'''# KEY=comment
OTHER_KEY=unrelated
KEY=first
  export KEY=last=with=equals
PLAIN=  plain value \x20
DOUBLE="  inside  "
SINGLE='single value'
UNMATCHED="open
EMPTY=""
LITERAL=$HOME $(echo nope) # text
CRLF=\t trimmed \r
QUOTED_CRLF=\t "quoted value" \r
SINGLE_CRLF= 'single value'\r
INNER_CR="inside\r"\r
OVERRIDE=first
OVERRIDE=
SPACES=\x20\x20\x20
SINGLE_EMPTY=''
LONE_DOUBLE="
LONE_SINGLE='
DOUBLE_SINGLE="'"
SINGLE_DOUBLE='"'
MISMATCHED="value'
NESTED="'value'"
ESCAPES="C:\\folder\\file\\n"
INNER_QUOTES="say "hello""
INLINE_COMMENT="value" # retained
PADDED="  "
QUOTED_TABS="\tinside\t"
QUOTED_EQUALS="left=middle=right"
QUOTED_HASH='value # literal'
CONTROL_PADDING=\x0b\x0cvalue\x0c\x0b
QUOTED_CONTROL="\x0bvalue\x0c"
GLOB="* ? [abc] {one,two} ~"
EXACT=correct
PREFIX_EXACT=wrong-prefix
EXACT_SUFFIX=wrong-suffix
exact=wrong-case
EXACT =wrong-space
exportEXACT=wrong-export
\texport\tTABBED=tabbed
COMMENTED=kept
  INDENTED_SPACE=space-prefixed
\tINDENTED_TAB=tab-prefixed
 \t export   EXPORT_SPACING=spaced-export
MIXED=plain-first
export MIXED=export-middle
MIXED=plain-last
EXPORT_EMPTY=plain-first
export EXPORT_EMPTY=
# COMMENTED=ignored
  # export COMMENTED=also-ignored
; COMMENTED=semicolon-prefix
FINAL=no-newline''')
    (pathlib.Path(directory) / 'empty').write_bytes(b'')
    (pathlib.Path(directory) / 'comments').write_bytes(b'# KEY=ignored\n  # export KEY=ignored\n\n')
    (pathlib.Path(directory) / 'linked').symlink_to(fixture)
    (pathlib.Path(directory) / 'linked [literal] file').symlink_to(fixture)
    (pathlib.Path(directory) / 'broken').symlink_to(fixture.with_name('missing'))
    result = subprocess.run(['bash', '-u', '-c', r'''
ROOT=$1
FIXTURE=$2
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
. "$ROOT/bin/fm-env-lib.sh"
assert_value() {
  local key=$1 expected=$2 got
  got=$(fmx_env_get "$key" "$FIXTURE") || fail "read [$key] failed"
  [ "$got" = "$expected" ] || fail "value [$key]: [$got]"
}
assert_value KEY 'last=with=equals'
assert_value MISSING ''
assert_value OTHER_KEY unrelated
assert_value OVERRIDE ''
pass 'last matching assignment wins, including empty overrides'
assert_value PLAIN 'plain value'
assert_value DOUBLE '  inside  '
assert_value SINGLE 'single value'
assert_value UNMATCHED '"open'
assert_value EMPTY ''
assert_value LITERAL '$HOME $(echo nope) # text'
assert_value CRLF trimmed
pass 'whitespace and matching quotes are stripped while content stays literal'
got=$(fmx_env_get KEY "$FIXTURE.missing") || fail 'missing file succeeds'
[ -z "$got" ] || fail 'missing file prints nothing'
assert_value SPACES ''
assert_value SINGLE_EMPTY ''
assert_value MISMATCHED "\"value'"
assert_value NESTED "'value'"
assert_value PADDED '  '
got=$(fmx_env_get KEY "${FIXTURE%/*}") || fail 'directory input succeeds'
[ -z "$got" ] || fail 'directory input prints nothing'
pass 'empty values, mismatched quotes, nested quotes, and directories stay literal or absent'
assert_value EXACT correct
assert_value TABBED tabbed
assert_value EXAC ''
assert_value Exact ''
pass 'keys match exactly and export requires separating whitespace'
assert_value INDENTED_SPACE space-prefixed
assert_value INDENTED_TAB tab-prefixed
assert_value EXPORT_SPACING spaced-export
pass 'plain assignments accept space and tab indentation and export accepts repeated spacing'
export KEY=environment-value MISSING=environment-only
assert_value KEY 'last=with=equals'
assert_value MISSING ''
got=$(fmx_env_get KEY "$FIXTURE.missing") || fail 'exported key with missing file succeeds'
[ -z "$got" ] || fail 'missing file does not fall back to exported value'
[ "$KEY" = environment-value ] || fail 'file read does not change exported value'
[ "$MISSING" = environment-only ] || fail 'absent key does not change exported value'
pass 'exported variables neither override file values nor supply absent values'
got=$(fmx_env_get KEY "${FIXTURE%/*}/linked") || fail 'linked file succeeds'
[ "$got" = 'last=with=equals' ] || fail 'linked file reads target value'
got=$(fmx_env_get KEY "${FIXTURE%/*}/broken") || fail 'broken link succeeds'
[ -z "$got" ] || fail 'broken link prints nothing'
pass 'regular-file symlinks read their targets and broken symlinks stay absent'
got=$(fmx_env_get KEY "${FIXTURE%/*}/linked [literal] file") || fail 'special-character path succeeds'
[ "$got" = 'last=with=equals' ] || fail 'special-character path reads the exact file'
pass 'file paths preserve spaces and literal glob characters'
for name in empty comments; do
  got=$(fmx_env_get KEY "${FIXTURE%/*}/$name" 2>&1) || fail "$name file succeeds"
  [ -z "$got" ] || fail "$name file prints nothing on either stream"
done
pass 'empty and comment-only files succeed without output or diagnostics'
assert_value COMMENTED kept
pass 'later commented and prefixed assignments do not replace a real value'
assert_value MIXED plain-last
assert_value EXPORT_EMPTY ''
pass 'plain and exported assignments share ordering and exported empty values override'
assert_value QUOTED_CRLF 'quoted value'
assert_value SINGLE_CRLF 'single value'
assert_value INNER_CR $'inside\r'
pass 'CRLF padding is removed before unquoting while quoted carriage returns survive'
assert_value ESCAPES 'C:\folder\file\n'
assert_value INNER_QUOTES 'say "hello"'
assert_value INLINE_COMMENT '"value" # retained'
pass 'backslashes and inner quotes stay literal and inline comments are retained'
assert_value QUOTED_TABS $'\tinside\t'
assert_value QUOTED_EQUALS 'left=middle=right'
assert_value QUOTED_HASH 'value # literal'
pass 'quoted tabs, equals signs, and hash characters survive parsing'
assert_value CONTROL_PADDING value
assert_value QUOTED_CONTROL $'\vvalue\f'
pass 'vertical tabs and form feeds trim outside quotes and survive inside quotes'
assert_value GLOB '* ? [abc] {one,two} ~'
pass 'quoted glob, brace, and tilde characters remain literal'
assert_value LONE_DOUBLE '"'
assert_value LONE_SINGLE "'"
assert_value DOUBLE_SINGLE "'"
assert_value SINGLE_DOUBLE '"'
pass 'lone quotes remain literal and matching outer quotes strip only one layer'
assert_value FINAL no-newline
got=$(fmx_env_get FINAL "$FIXTURE"; printf sentinel)
[ "$got" = no-newlinesentinel ] || fail 'value has no appended newline'
pass 'missing files succeed and final lines need no newline'
(
  set -e -o pipefail
  got=$(fmx_env_get KEY "$FIXTURE")
  [ "$got" = 'last=with=equals' ] || fail 'strict shell reads present key'
  got=$(fmx_env_get MISSING "$FIXTURE")
  [ -z "$got" ] || fail 'strict shell absent key prints nothing'
  got=$(fmx_env_get KEY "$FIXTURE.missing")
  [ -z "$got" ] || fail 'strict shell missing file prints nothing'
  got=$(fmx_env_get EMPTY "$FIXTURE")
  [ -z "$got" ] || fail 'strict shell empty value prints nothing'
)
pass 'errexit and pipefail callers can read present, absent, and empty values'
(
  set -e -o pipefail
  grep() { printf 'fixture read failed\n' >&2; return 2; }
  got=$(fmx_env_get KEY "$FIXTURE" 2>&1)
  [ -z "$got" ] || fail 'failed read prints nothing on either stream'
)
pass 'failed reads succeed silently under errexit and pipefail'
''', 'fm-env-test', sys.argv[1], str(fixture)], check=False)
    sys.exit(result.returncode)
PY
