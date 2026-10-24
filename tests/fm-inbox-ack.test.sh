#!/usr/bin/env bash
# tests/fm-inbox-ack.test.sh - bin/fm-inbox-ack.sh, the one-command
# acknowledgement a worker runs instead of a bare `mv` into handled/.
# It moves <task>.inbox/NNN.msg into that same inbox's handled/ and refuses
# everything else; a re-run on an already-handled message is a quiet success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACK="$ROOT/bin/fm-inbox-ack.sh"
# Exercise the no-export fallback explicitly unless an individual call sets it.
unset FM_TASK_INBOX
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-ack.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

new_inbox() {  # <name> -> path of a fresh <name>.inbox with 001 and 002
  local d="$TMP/$1.inbox"
  mkdir -p "$d/handled"
  printf 'one\n' > "$d/001.msg"
  printf 'two\n' > "$d/002.msg"
  printf '%s' "$d"
}

test_moves_via_env_and_flag() {
  local d out
  d=$(new_inbox t1)
  out=$(FM_TASK_INBOX="$d" bash "$ACK" 001) || fail "ack through FM_TASK_INBOX failed"
  assert_contains "$out" "handled: 001" "ack did not report the move"
  [ ! -e "$d/001.msg" ] && [ -f "$d/handled/001.msg" ] || fail "001 did not move into handled/"
  [ -f "$d/002.msg" ] || fail "an unnamed message was touched"
  bash "$ACK" --inbox "$d" 002.msg >/dev/null || fail "ack through --inbox failed"
  [ -f "$d/handled/002.msg" ] || fail "002 did not move into handled/"
  [ "$(cat "$d/handled/001.msg")" = one ] || fail "message content changed"
  pass "ack: moves exactly the named messages into handled/"
}

test_env_inbox_cannot_be_overridden() {
  local a b rc=0
  a=$(new_inbox a)
  b=$(new_inbox b)
  FM_TASK_INBOX="$a" bash "$ACK" --inbox "$b" 001 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "--inbox must not override FM_TASK_INBOX"
  [ -f "$a/001.msg" ] && [ -f "$b/001.msg" ] \
    || fail "a mismatched --inbox moved a message"
  FM_TASK_INBOX="$a" bash "$ACK" --inbox "$a" 001 >/dev/null \
    || fail "a matching --inbox should succeed"
  [ -f "$a/handled/001.msg" ] && [ -f "$b/001.msg" ] \
    || fail "a matching --inbox did not handle only its own message"
  pass "ack: FM_TASK_INBOX cannot be overridden by a sibling inbox"
}

test_several_ids() {
  local d
  d=$(new_inbox t2)
  bash "$ACK" --inbox "$d" 001 002 >/dev/null || fail "ack of two ids failed"
  [ -f "$d/handled/001.msg" ] && [ -f "$d/handled/002.msg" ] || fail "both ids should be handled"
  pass "ack: several ids in one call"
}

test_rerun_is_safe() {
  local d out
  d=$(new_inbox t3)
  bash "$ACK" --inbox "$d" 001 >/dev/null || fail "first ack failed"
  out=$(bash "$ACK" --inbox "$d" 001) || fail "re-run on a handled message must succeed"
  assert_contains "$out" "already handled" "re-run did not say it was already handled"
  [ "$(cat "$d/handled/001.msg")" = one ] || fail "re-run changed the handled message"
  pass "ack: re-run on a handled message is a quiet success"
}

test_missing_message() {
  local d rc=0
  d=$(new_inbox t4)
  bash "$ACK" --inbox "$d" 009 >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a message found nowhere should exit 1"
  pass "ack: a missing message exits 1"
}

refuses() {  # <label> <args...>
  local label=$1 rc=0
  shift
  bash "$ACK" "$@" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "$label should be refused"
}

test_refusals() {
  local d
  d=$(new_inbox t5)
  refuses "path traversal id" --inbox "$d" ../001
  refuses "absolute id" --inbox "$d" "$TMP/t5.inbox/001"
  refuses "non-numeric id" --inbox "$d" abc
  refuses "empty id" --inbox "$d" ""
  [ -f "$d/001.msg" ] || fail "a refused call moved a message"

  mkdir -p "$TMP/plain/handled"
  printf 'x\n' > "$TMP/plain/001.msg"
  refuses "a directory not named <task>.inbox" --inbox "$TMP/plain" 001
  refuses "a missing inbox" --inbox "$TMP/none.inbox" 001
  env -u FM_TASK_INBOX bash "$ACK" 001 >/dev/null 2>&1
  expect_code 2 "$?" "no inbox at all should be refused"

  mkdir -p "$TMP/real.inbox/handled"
  ln -s "$TMP/real.inbox" "$TMP/link.inbox"
  printf 'x\n' > "$TMP/real.inbox/001.msg"
  refuses "a symlinked inbox" --inbox "$TMP/link.inbox" 001
  [ -f "$TMP/real.inbox/001.msg" ] || fail "a symlinked inbox was followed"

  mkdir -p "$TMP/esc.inbox" "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$TMP/esc.inbox/handled"
  printf 'x\n' > "$TMP/esc.inbox/001.msg"
  refuses "a symlinked handled/" --inbox "$TMP/esc.inbox" 001
  [ -f "$TMP/esc.inbox/001.msg" ] && [ -z "$(ls "$TMP/elsewhere")" ] || fail "handled/ symlink escaped"

  mkdir -p "$TMP/sym.inbox/handled"
  printf 'secret\n' > "$TMP/secret"
  ln -s "$TMP/secret" "$TMP/sym.inbox/001.msg"
  refuses "a symlinked message" --inbox "$TMP/sym.inbox" 001
  [ -f "$TMP/secret" ] && [ -L "$TMP/sym.inbox/001.msg" ] || fail "a symlinked message was moved"

  printf 'old\n' > "$d/handled/002.msg"
  refuses "a collision with a different handled message" --inbox "$d" 002
  [ "$(cat "$d/handled/002.msg")" = old ] || fail "a handled message was overwritten"
  pass "ack: refuses traversal, foreign dirs, symlinks, and collisions without moving anything"
}

test_bad_id_moves_nothing() {
  local d rc=0
  d=$(new_inbox t6)
  bash "$ACK" --inbox "$d" 001 abc >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a bad id after a good one should be refused"
  [ -f "$d/001.msg" ] && [ ! -e "$d/handled/001.msg" ] || fail "a good id moved before a bad id was refused"
  pass "ack: one bad id refuses the whole call and nothing moves"
}

test_invalid_entries_move_nothing() {
  local d location kind entry rc
  for location in source handled; do
    for kind in directory fifo symlink dangling; do
      d=$(new_inbox "invalid-$location-$kind")
      if [ "$location" = source ]; then
        entry="$d/003.msg"
      else
        entry="$d/handled/003.msg"
      fi
      case "$kind" in
        directory) mkdir "$entry" ;;
        fifo) mkfifo "$entry" ;;
        symlink) ln -s "$d/002.msg" "$entry" ;;
        dangling) ln -s "$d/absent" "$entry" ;;
      esac
      rc=0
      bash "$ACK" --inbox "$d" 001 003 >/dev/null 2>&1 || rc=$?
      expect_code 2 "$rc" "a $kind $location entry should refuse the whole call"
      [ -f "$d/001.msg" ] && [ ! -e "$d/handled/001.msg" ] \
        || fail "001 moved before an invalid $location entry was refused"
    done
  done
  d="$TMP/directory-second.inbox"
  mkdir -p "$d/handled" "$d/002.msg"
  printf 'one\n' > "$d/001.msg"
  refuses "a directory after a regular message" --inbox "$d" 001 002
  [ -f "$d/001.msg" ] && [ ! -e "$d/handled/001.msg" ] \
    || fail "001 moved before directory 002 was refused"
  pass "ack: invalid source and handled entries refuse all moves"
}

test_moves_via_env_and_flag
test_env_inbox_cannot_be_overridden
test_several_ids
test_rerun_is_safe
test_missing_message
test_refusals
test_bad_id_moves_nothing
test_invalid_entries_move_nothing
