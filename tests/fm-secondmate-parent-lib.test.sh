#!/usr/bin/env bash
# Pure parent binding record validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$ROOT/bin/fm-secondmate-parent-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
RECORD="$TMP/parent"

test_valid_records() {
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local 'parent_home=/a path/世界=home' future=value > "$RECORD"
  fm_secondmate_parent_record_parse "$RECORD" || fail "local record status"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || fail "local route"
  [ "$FM_SECONDMATE_PARENT_HOME" = '/a path/世界=home' ] || fail "literal local home"
  [ -z "$FM_SECONDMATE_PARENT_HOST" ] || fail "local host empty"
  printf '%s\n' route=remote schema=fm-secondmate-parent.v1 parent_host=ssh-alias > "$RECORD"
  fm_secondmate_parent_record_parse "$RECORD" || fail "remote record status"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ] || fail "remote route"
  [ -z "$FM_SECONDMATE_PARENT_HOME" ] || fail "remote home empty"
  [ "$FM_SECONDMATE_PARENT_HOST" = ssh-alias ] || fail "diagnostic host"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote' > "$RECORD"
  fm_secondmate_parent_record_parse "$RECORD" || fail "legacy remote without final newline"
  [ -z "$FM_SECONDMATE_PARENT_HOST" ] || fail "legacy host empty"
  pass "local and remote bindings preserve values and accept reserved fields"
}

test_invalid_records() {
  local fields
  for fields in \
    '' \
    'route=remote' \
    $'schema=wrong\nroute=remote' \
    $'schema=fm-secondmate-parent.v1\nroute=unknown' \
    $'schema=fm-secondmate-parent.v1\nroute=remote\nroute=remote' \
    $'schema=fm-secondmate-parent.v1\nschema=fm-secondmate-parent.v1\nroute=remote' \
    $'schema=fm-secondmate-parent.v1\nroute=local' \
    $'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=relative' \
    $'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=/one\nparent_home=/two' \
    $'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=/one\nparent_host=' \
    $'schema=fm-secondmate-parent.v1\nroute=remote\nparent_home='; do
    printf '%s\n' "$fields" > "$RECORD"
    FM_SECONDMATE_PARENT_ROUTE=stale
    FM_SECONDMATE_PARENT_HOME=stale
    FM_SECONDMATE_PARENT_HOST=stale
    fm_secondmate_parent_record_parse "$RECORD" && fail "invalid record accepted: $fields"
    [ -z "$FM_SECONDMATE_PARENT_ROUTE$FM_SECONDMATE_PARENT_HOME$FM_SECONDMATE_PARENT_HOST" ] || fail "rejection clears outputs"
  done
  pass "missing, unsupported, duplicate, and conflicting bindings fail closed"
}

test_file_rejection() {
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=/a\0b\n' > "$RECORD"
  fm_secondmate_parent_record_parse "$RECORD" && fail "NUL accepted"
  ln -s "$RECORD" "$TMP/link"
  fm_secondmate_parent_record_parse "$TMP/link" && fail "symlink accepted"
  fm_secondmate_parent_record_parse "$TMP/missing" && fail "missing file accepted"
  fm_secondmate_parent_record_parse "$TMP" && fail "directory accepted"
  pass "NUL records, symlinks, absent files, and directories are refused"
}

test_valid_records
test_invalid_records
test_file_rejection
