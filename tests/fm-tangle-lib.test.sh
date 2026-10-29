#!/usr/bin/env bash
# Read-only worktree-tangle checks against the real checkout.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

test_default_branch() {
  local expected got rc
  expected=$(git -C "$ROOT" rev-parse --abbrev-ref origin/HEAD 2>/dev/null)
  if [ -n "$expected" ]; then
    expected=${expected#origin/}
  elif git -C "$ROOT" branch --list main | command grep -q main; then
    expected=main
  elif git -C "$ROOT" branch --list master | command grep -q master; then
    expected=master
  else
    fail 'checkout must have a discoverable default branch'
  fi
  got=$(fm_default_branch "$ROOT"); rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = "$expected" ] || fail 'real default branch'
  got=$(fm_default_branch "$ROOT"; printf '|')
  [ "$got" = "$expected"$'\n|' ] || fail 'default branch newline'
  pass 'default branch agrees with real Git refs and ends with a newline'
}

test_current_checkout() {
  local current default got rc
  current=$(git -C "$ROOT" branch --show-current)
  default=$(fm_default_branch "$ROOT")
  got=$(fm_primary_tangle_branch "$ROOT" 2>&1); rc=$?
  if [ -z "$current" ] || [ "$current" = "$default" ]; then
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'healthy checkout must be silent'
  else
    [ "$rc" -eq 0 ] && [ "$got" = "$current" ] || fail 'named feature branch detection'
    got=$(fm_primary_tangle_branch "$ROOT"; printf '|')
    [ "$got" = "$current"$'\n|' ] || fail 'tangled branch newline'
  fi
  pass 'checkout classification agrees with its current branch without mutating Git'
}

test_invalid_roots() {
  local path got rc
  for path in /dev/null /dev/null/firstmate-missing-worktree; do
    got=$(fm_primary_tangle_branch "$path" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'non-worktree refuses silently'
    got=$(fm_default_branch "$path" 2>/dev/null); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'invalid root has no default branch'
  done
  pass 'non-directory and impossible roots cannot produce a branch'
}

test_default_branch
test_current_checkout
test_invalid_roots
