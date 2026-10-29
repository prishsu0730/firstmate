#!/usr/bin/env bash
# Receiver input and destination refusals without remote connections.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records"
unset FM_INHERITABLE_CONFIG
mkdir -p "$FM_HOME" "$TMP/outside"
HASH=$(printf '' | shasum -a 256 | awk '{print $1}')
expect_refusal() {
  local expected=$1 message=$2 rc
  shift 2
  bash "$ROOT/bin/fm-remote-inherit.sh" "$@" < /dev/null > "$TMP/stdout" 2> "$TMP/stderr"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc: $(cat "$TMP/stderr")"
  case "$(cat "$TMP/stderr")" in *"$message"*) ;; *) fail "missing diagnostic: $message" ;; esac
}

test_commitments() {
  local value
  bash "$ROOT/bin/fm-remote-inherit.sh" > "$TMP/stdout" 2> "$TMP/stderr"
  [ "$?" -eq 2 ] || fail 'missing arguments status'
  case "$(cat "$TMP/stdout")" in *Usage:*) ;; *) fail 'usage output' ;; esac
  for value in ../escape config/secondmate-harness data/captain.md /tmp/outside; do
    expect_refusal 1 'path is not inherited material' put "$value" 0 "$HASH" 1
  done
  for value in '' -1 1x; do
    expect_refusal 1 'nonnegative integer' put config/crew-harness "$value" "$HASH" 1
  done
  for value in 1048577 99999999999; do
    expect_refusal 1 'exceed the byte bound' put config/crew-harness "$value" "$HASH" 1
  done
  expect_refusal 1 'SHA-256 is invalid' put config/crew-harness 0 zz 1
  expect_refusal 1 'wrong length' put config/crew-harness 0 ab 1
  for value in '' -1 1x; do
    expect_refusal 1 'positive integer' put config/crew-harness 0 "$HASH" "$value"
  done
  for value in 0 9999999999999999999; do
    expect_refusal 1 'outside the supported range' put config/crew-harness 0 "$HASH" "$value"
  done
  [ ! -e "$FM_HOME/config" ] || fail 'invalid commitments created a destination parent'
  pass 'invalid arity, paths, lengths, digests and generations fail before destination creation'
}

test_parent() {
  FM_HOME="$TMP/missing" expect_refusal 1 'FM_HOME is unavailable' put config/crew-harness 0 "$HASH" 1
  ln -s "$TMP/outside" "$FM_HOME/config"
  expect_refusal 1 'parent is a symlink' put config/crew-harness 0 "$HASH" 1
  [ ! -e "$TMP/outside/crew-harness" ] || fail 'symlink parent was written'
  pass 'missing homes and symlink parents are refused'
}

test_destination() {
  local fixture
  for fixture in symlink directory hardlink; do
    export FM_HOME="$TMP/$fixture"
    mkdir -p "$FM_HOME/config"
    case "$fixture" in
      symlink) ln -s "$TMP/outside/target" "$FM_HOME/config/crew-harness" ;;
      directory) mkdir "$FM_HOME/config/crew-harness" ;;
      hardlink)
        printf 'preserve\n' > "$TMP/outside/target"
        ln "$TMP/outside/target" "$FM_HOME/config/crew-harness"
        ;;
    esac
    case "$fixture" in
      symlink) expect_refusal 1 'destination is a symlink' put config/crew-harness 0 "$HASH" 1 ;;
      directory) expect_refusal 1 'not a regular file' put config/crew-harness 0 "$HASH" 1 ;;
      hardlink) expect_refusal 1 'destination is hardlinked' put config/crew-harness 0 "$HASH" 1 ;;
    esac
    [ ! -e "$FM_HOME/config/.fm-inherit-crew-harness.generation" ] || fail 'refusal committed a generation'
  done
  [ "$(cat "$TMP/outside/target")" = preserve ] || fail 'hardlinked content changed'
  pass 'symlink, directory and hardlinked destinations preserve content and generation state'
}

test_commitments
test_parent
test_destination
