#!/usr/bin/env bash
# Capacity declaration parsing without fleet or runtime services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$ROOT/bin/fm-project-capacity-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
mkdir "$TMP/absent" "$TMP/declared" "$TMP/nonfile"
RECORD="$TMP/declared/project-capacity"

lookup() { fm_project_capacity_lookup "$TMP/declared" "$1"; }

test_defaults() {
  FM_PROJECT_CAPACITY=stale
  FM_PROJECT_CAPACITY_ANY=stale
  FM_PROJECT_CAPACITY_ERROR=stale
  fm_project_capacity_lookup "$TMP/absent" repo || fail "missing declaration"
  [ "$FM_PROJECT_CAPACITY_FILE" = "$TMP/absent/project-capacity" ] || fail "declaration path"
  [ -z "$FM_PROJECT_CAPACITY$FM_PROJECT_CAPACITY_ANY$FM_PROJECT_CAPACITY_ERROR" ] || fail "missing declaration retains results"
  printf '# comment\n\n#\n# note 12\n#another-note\n' > "$RECORD"
  lookup repo || fail "comments only"
  [ -z "$FM_PROJECT_CAPACITY$FM_PROJECT_CAPACITY_ANY" ] || fail "comments declare capacity"
  pass "absent and comment-only declarations remain uncapped and clear prior results"
}

test_valid_declarations() {
  printf '  repo\t2\r\nproject with spaces 999999\n#repo 3\nlast 1' > "$RECORD"
  lookup repo || fail "whitespace and CRLF"
  [ "$FM_PROJECT_CAPACITY" = 2 ] || fail "repo capacity"
  [ "$FM_PROJECT_CAPACITY_ANY" = 1 ] || fail "any capacity marker"
  lookup 'project with spaces' || fail "spaced name"
  [ "$FM_PROJECT_CAPACITY" = 999999 ] || fail "six digit limit"
  lookup '#repo' || fail "hash name"
  [ "$FM_PROJECT_CAPACITY" = 3 ] || fail "hash name capacity"
  lookup last || fail "unterminated final line"
  [ "$FM_PROJECT_CAPACITY" = 1 ] || fail "final capacity"
  lookup missing || fail "unlisted project"
  [ -z "$FM_PROJECT_CAPACITY$FM_PROJECT_CAPACITY_ERROR" ] || fail "unlisted project retains capacity"
  [ "$FM_PROJECT_CAPACITY_ANY" = 1 ] || fail "unlisted project loses declaration marker"
  pass "names, whitespace, CRLF, final lines and capacity boundaries parse"
}

test_invalid_declarations() {
  local declaration
  for declaration in 'broken' 'other 0' 'other 01' 'other -1' 'other 1.5' 'other nope' 'other 1000000' 'repo 3'; do
    printf 'repo 2\n%s\n' "$declaration" > "$RECORD"
    lookup repo && fail "invalid declaration accepted: $declaration"
    [ -z "$FM_PROJECT_CAPACITY" ] || fail "invalid declaration retains matched capacity"
    case "$FM_PROJECT_CAPACITY_ERROR" in
      "$RECORD line 2 "*) ;;
      *) fail "missing path and line diagnostic: $declaration" ;;
    esac
  done
  printf 'other 1\nother 2\n' > "$RECORD"
  lookup missing && fail "duplicate unrelated project accepted"
  pass "malformed and duplicate declarations invalidate the entire file"
}

test_nonfiles() {
  mkdir "$TMP/nonfile/project-capacity"
  fm_project_capacity_lookup "$TMP/nonfile" repo && fail "directory accepted"
  [ "$FM_PROJECT_CAPACITY_ERROR" = "$TMP/nonfile/project-capacity is not a readable regular file" ] || fail "directory diagnostic"
  mkdir "$TMP/dangling"
  ln -s "$TMP/missing" "$TMP/dangling/project-capacity"
  fm_project_capacity_lookup "$TMP/dangling" repo && fail "dangling link accepted as absent"
  [ -n "$FM_PROJECT_CAPACITY_ERROR" ] || fail "dangling link diagnostic"
  pass "directories and dangling declarations refuse"
}

test_defaults
test_valid_declarations
test_invalid_declarations
test_nonfiles
