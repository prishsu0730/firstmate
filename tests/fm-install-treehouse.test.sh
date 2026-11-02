#!/usr/bin/env bash
# Installer early refusals without downloads or installed tools.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64
export FM_TEST_DOWNLOAD_LOG="$TMP/download"
uname() {
  case "${1:-}" in
    -s) printf '%s\n' "$FM_TEST_UNAME_S" ;;
    -m) printf '%s\n' "$FM_TEST_UNAME_M" ;;
    *) return 1 ;;
  esac
}
curl() { printf 'unexpected download\n' >> "$FM_TEST_DOWNLOAD_LOG"; return 99; }
export -f uname curl

expect_refusal() {
  local expected=$1 rc
  shift
  bash "$ROOT/bin/fm-install-treehouse.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"
  rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1, got $rc"
  grep -Fq "$expected" "$TMP/stderr" || fail "missing diagnostic: $expected"
  [ ! -s "$TMP/stdout" ] || fail 'refusal wrote stdout'
  [ ! -e "$FM_TEST_DOWNLOAD_LOG" ] || fail 'refusal attempted download'
  [ ! -e "$TMP/destination" ] || fail 'refusal created destination'
}

test_destination_required() {
  expect_refusal 'usage: fm-install-treehouse.sh <destination-directory>'
  expect_refusal 'usage: fm-install-treehouse.sh <destination-directory>' ''
  pass 'absent and empty destinations fail before download'
}

test_unsupported_os() {
  export FM_TEST_UNAME_S=FreeBSD FM_TEST_UNAME_M=x86_64
  expect_refusal 'unsupported platform FreeBSD-x86_64' "$TMP/destination"
  pass 'unsupported operating system fails without creating destination'
}

test_unsupported_arch() {
  export FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=ppc64le
  expect_refusal 'unsupported platform Linux-ppc64le' "$TMP/destination"
  export FM_TEST_UNAME_S=Darwin FM_TEST_UNAME_M=i386
  expect_refusal 'unsupported platform Darwin-i386' "$TMP/destination"
  pass 'unsupported Linux and Darwin architectures fail before download'
}

test_destination_required
test_unsupported_os
test_unsupported_arch
