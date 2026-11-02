#!/usr/bin/env bash
# Custom check registration binds bytes and refuses unsafe artifacts without services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTER="$ROOT/bin/fm-check-register.sh"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT

expect_registration() {
  local state=$1 expected=$2 rc
  shift 2
  FM_HOME="$TMP/unused-home" FM_STATE_OVERRIDE="$state" \
    bash "$REGISTER" "$@" > "$TMP/out" 2> "$TMP/err"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "registration status $rc instead of $expected"
  if [ "$expected" -ne 0 ]; then
    [ ! -s "$TMP/out" ] || fail "refusal reported success"
    [ -s "$TMP/err" ] || fail "refusal lacked diagnostic"
  fi
}

write_check() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nprintf ready\\n\n' > "$1/custom.check.sh"
  chmod 0700 "$1/custom.check.sh"
}

test_binding_and_refresh() {
  local state="$TMP/binding" original
  write_check "$state"
  expect_registration "$state" 0 custom
  [ "$(cat "$TMP/out")" = 'registered: state/custom.check.sh' ] || fail "success output"
  [ ! -s "$TMP/err" ] || fail "unexpected diagnostic"
  [ "$(fm_pr_file_mode "$state/custom.check-trust")" = 600 ] || fail "trust permissions"
  original=$(cat "$state/custom.check-trust")
  [ "$original" = "$(printf 'fm-custom-check-v1\n%s' "$(fm_custom_check_sha256 "$state/custom.check.sh")")" ] \
    || fail "trust record shape or digest"
  fm_custom_check_registered "$state" custom || fail "registration not consumable"
  expect_registration "$state" 0 custom
  [ "$(cat "$state/custom.check-trust")" = "$original" ] || fail "repeat changed binding"
  printf '# changed\n' >> "$state/custom.check.sh"
  fm_custom_check_registered "$state" custom && fail "changed bytes still trusted"
  expect_registration "$state" 0 custom
  [ "$(cat "$state/custom.check-trust")" != "$original" ] || fail "digest not refreshed"
  fm_custom_check_registered "$state" custom || fail "refreshed binding rejected"
  [ -z "$(find "$state" -name '.fm-custom-check-trust.*' -print)" ] || fail "temporary binding left behind"
  [ ! -e "$TMP/unused-home" ] || fail "state override ignored"
  pass "private digest binding, repeat registration, refresh, and temporary cleanup"
}

test_arguments_and_state() {
  local id state="$TMP/arguments"
  write_check "$state"
  expect_registration "$state" 2
  expect_registration "$state" 2 custom extra
  for id in '' ../escape 'two words' /absolute; do
    expect_registration "$state" 2 "$id"
  done
  [ ! -e "$state/custom.check-trust" ] || fail "invalid arguments wrote trust"
  expect_registration "$TMP/missing" 1 custom
  ln -s "$state" "$TMP/state-link"
  expect_registration "$TMP/state-link" 1 custom
  [ ! -e "$state/custom.check-trust" ] || fail "linked state wrote trust"
  pass "invalid argument counts, unsafe IDs, missing state, and symlinked state"
}

test_unsafe_checks() {
  local state="$TMP/unsafe-checks" kind
  for kind in missing directory symlink hardlink mode; do
    state="$TMP/unsafe-checks-$kind"
    mkdir "$state"
    case "$kind" in
      missing) ;;
      directory) mkdir "$state/custom.check.sh" ;;
      symlink)
        write_check "$state/target"
        ln -s "$state/target/custom.check.sh" "$state/custom.check.sh"
        ;;
      hardlink)
        write_check "$state"
        ln "$state/custom.check.sh" "$state/alias"
        ;;
      mode) write_check "$state"; chmod 0755 "$state/custom.check.sh" ;;
    esac
    expect_registration "$state" 1 custom
    [ ! -e "$state/custom.check-trust" ] || fail "$kind check created trust"
  done
  pass "missing, nonregular, linked, and nonprivate checks refuse registration"
}

test_unsafe_trust() {
  local state kind
  for kind in directory symlink dangling hardlink; do
    state="$TMP/unsafe-trust-$kind"
    write_check "$state"
    printf 'preserve\n' > "$state/canary"
    case "$kind" in
      directory) mkdir "$state/custom.check-trust" ;;
      symlink) ln -s "$state/canary" "$state/custom.check-trust" ;;
      dangling) ln -s "$state/absent" "$state/custom.check-trust" ;;
      hardlink) ln "$state/canary" "$state/custom.check-trust" ;;
    esac
    expect_registration "$state" 1 custom
    [ "$(cat "$state/canary")" = preserve ] || fail "$kind destination changed target"
    [ ! -e "$state/absent" ] || fail "dangling target created"
    [ -z "$(find "$state" -name '.fm-custom-check-trust.*' -print)" ] || fail "refusal left temporary file"
  done
  pass "unsafe trust destinations refuse registration and preserve targets"
}

test_binding_and_refresh
test_arguments_and_state
test_unsafe_checks
test_unsafe_trust
