#!/usr/bin/env bash
# Backlog receipt input and confinement refusals without remote connections.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records"
mkdir -p "$FM_HOME" "$TMP/outside"
HASH=$(printf '' | shasum -a 256 | awk '{print $1}')
expect_refusal() {
  local expected=$1 message=$2 rc
  shift 2
  bash "$ROOT/bin/fm-backlog-receive.sh" "$@" < /dev/null > "$TMP/stdout" 2> "$TMP/stderr"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc: $(cat "$TMP/stderr")"
  case "$(cat "$TMP/stderr")" in *"$message"*) ;; *) fail "missing diagnostic: $message" ;; esac
}

test_commitments() {
  local value
  bash "$ROOT/bin/fm-backlog-receive.sh" > "$TMP/stdout" 2> "$TMP/stderr"
  [ "$?" -eq 2 ] || fail 'missing arguments status'
  case "$(cat "$TMP/stdout")" in *Usage:*) ;; *) fail 'usage output' ;; esac
  for value in '' -1 1x; do
    expect_refusal 1 'nonnegative integer' state/handoff/alpha.outbox.md "$value" "$HASH" 1
  done
  for value in 1048577 99999999999; do
    expect_refusal 1 'outside the supported range' state/handoff/alpha.outbox.md "$value" "$HASH" 1
  done
  expect_refusal 1 'SHA-256 is invalid' state/handoff/alpha.outbox.md 0 zz 1
  expect_refusal 1 'wrong length' state/handoff/alpha.outbox.md 0 ab 1
  for value in '' -1 1x; do
    expect_refusal 1 'positive integer' state/handoff/alpha.outbox.md 0 "$HASH" "$value"
  done
  for value in 0 9999999999999999999; do
    expect_refusal 1 'outside the supported range' state/handoff/alpha.outbox.md 0 "$HASH" "$value"
  done
  [ ! -e "$FM_HOME/data" ] || fail 'invalid commitments created backlog parent'
  pass 'invalid arity, byte bounds, digests and generations fail before backlog creation'
}

test_paths() {
  local value
  for value in ../escape /tmp/alpha.outbox.md state/alpha.outbox.md state/handoff/alpha.md; do
    expect_refusal 1 'outside state/handoff' "$value" 0 "$HASH" 1
  done
  for value in state/handoff/../alpha.outbox.md state/handoff/./alpha.outbox.md; do
    expect_refusal 1 'contains traversal' "$value" 0 "$HASH" 1
  done
  expect_refusal 1 'path is malformed' state/handoff//alpha.outbox.md 0 "$HASH" 1
  [ ! -e "$FM_HOME/state" ] || fail 'unsafe paths created handoff directory'
  pass 'absolute, outside, traversal and repeated-separator paths are refused'
}

test_home() {
  expect_refusal 1 'not a seeded secondmate home' state/handoff/alpha.outbox.md 0 "$HASH" 1
  printf 'seed\n' > "$TMP/seed"
  ln -s "$TMP/seed" "$FM_HOME/.fm-secondmate-home"
  expect_refusal 1 'not a seeded secondmate home' state/handoff/alpha.outbox.md 0 "$HASH" 1
  export FM_HOME="$TMP/seeded"
  mkdir -p "$FM_HOME/bin" "$FM_HOME/state"
  touch "$FM_HOME/.fm-secondmate-home"
  expect_refusal 1 'not a Firstmate home' state/handoff/alpha.outbox.md 0 "$HASH" 1
  touch "$FM_HOME/AGENTS.md"
  expect_refusal 1 'parent is unavailable' state/handoff/alpha.outbox.md 0 "$HASH" 1
  ln -s "$TMP/outside" "$FM_HOME/state/handoff"
  expect_refusal 1 'escapes the remote scratch directory' state/handoff/alpha.outbox.md 0 "$HASH" 1
  [ ! -e "$FM_HOME/data" ] || fail 'unsafe home created backlog parent'
  [ -z "$(ls -A "$TMP/outside")" ] || fail 'escaped scratch directory was written'
  pass 'unseeded, symlink-seeded, incomplete and escaped homes are refused without mutation'
}

test_commitments
test_paths
test_home
