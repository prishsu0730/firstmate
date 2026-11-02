#!/usr/bin/env bash
# Fast-forward home validation without Git operations or remote hosts.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_ROOT="$TMP/repo"
export FM_HOME="$TMP/active"
mkdir -p "$FM_ROOT" "$FM_HOME" "$TMP/mate/bin" "$TMP/outside"
printf 'mate\n' > "$TMP/mate/.fm-secondmate-home"
: > "$TMP/mate/AGENTS.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"

refuse() {
  local expected=$1 home=$2
  VALIDATED_HOME=stale
  validate_secondmate_home mate "$home" && fail "unsafe home accepted: $home"
  [ -z "$VALIDATED_HOME" ] || fail "stale validated home retained"
  [ "$VALIDATION_ERROR" = "$expected" ] || fail "wrong refusal: $VALIDATION_ERROR"
}

test_home_boundaries() {
  validate_secondmate_home mate "$TMP/mate" || fail "valid home: $VALIDATION_ERROR"
  [ "$VALIDATED_HOME" = "$(cd "$TMP/mate" && pwd -P)" ] || fail "canonical home"
  [ -z "$VALIDATION_ERROR" ] || fail "valid home retained error"
  refuse 'not a directory' "$TMP/missing"
  refuse 'secondmate home cannot be the filesystem root' /
  refuse 'secondmate home cannot be the active firstmate home' "$FM_HOME"
  refuse 'secondmate home cannot be the firstmate repo' "$FM_ROOT"
  mkdir -p "$FM_HOME/child" "$FM_ROOT/child"
  refuse 'secondmate home cannot be inside the active firstmate home' "$FM_HOME/child"
  refuse 'secondmate home cannot be inside the firstmate repo' "$FM_ROOT/child"
  refuse 'secondmate home cannot be an ancestor of the active firstmate home' "$TMP"
  pass "valid homes resolve canonically and overlapping homes are refused"
}

test_operational_paths() {
  local name
  for name in data state config projects; do
    ln -s "$TMP/outside" "$TMP/mate/$name"
    refuse "secondmate $name directory must resolve inside the secondmate home" "$TMP/mate"
    unlink "$TMP/mate/$name"
    ln -s "$TMP/missing" "$TMP/mate/$name"
    refuse "secondmate $name directory must resolve inside the secondmate home" "$TMP/mate"
    unlink "$TMP/mate/$name"
    : > "$TMP/mate/$name"
    refuse "secondmate $name path is not a directory" "$TMP/mate"
    unlink "$TMP/mate/$name"
    mkdir "$TMP/mate/$name"
  done
  validate_secondmate_home mate "$TMP/mate" || fail "internal operational directories"
  pass "operational paths reject escaping and dangling symlinks and regular files"
}

test_identity() {
  validate_secondmate_home other "$TMP/mate" && fail "mismatched identity accepted"
  [ "$VALIDATION_ERROR" = 'marked for secondmate mate, expected other' ] || fail "identity diagnostic"
  unlink "$TMP/mate/.fm-secondmate-home"
  refuse 'not a seeded secondmate home' "$TMP/mate"
  printf 'mate\n' > "$TMP/marker"
  ln -s "$TMP/marker" "$TMP/mate/.fm-secondmate-home"
  refuse 'secondmate marker must not be a symlink' "$TMP/mate"
  unlink "$TMP/mate/.fm-secondmate-home"
  printf 'mate\n' > "$TMP/mate/.fm-secondmate-home"
  unlink "$TMP/mate/AGENTS.md"
  refuse 'not a firstmate home (missing AGENTS.md)' "$TMP/mate"
  : > "$TMP/mate/AGENTS.md"
  rmdir "$TMP/mate/bin"
  refuse 'not a firstmate home (missing bin/)' "$TMP/mate"
  pass "seed identity and required home structure are enforced"
}

test_home_boundaries
test_operational_paths
test_identity
echo '# fm-ff-lib.test.sh: all assertions passed'
