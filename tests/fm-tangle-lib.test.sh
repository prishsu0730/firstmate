#!/usr/bin/env bash
# Worktree-tangle checks against disposable Git refs.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh" || fail 'test helper setup'
TMP=$(fm_test_tmproot fm-tangle-test) || fail 'fixture directory'
REPO="$TMP/repo"
fm_git_init_commit "$REPO" || fail 'fixture setup'

test_default_branch() {
  local expected got rc
  for expected in main master trunk; do
    case "$expected" in
      master) git -C "$REPO" branch -m master || fail 'rename default' ;;
      trunk)
        git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD || fail 'remote default ref'
        git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk || fail 'remote HEAD'
        ;;
    esac
    got=$(fm_default_branch "$REPO"); rc=$?
    [ "$rc" -eq 0 ] && [ "$got" = "$expected" ] || fail 'fixture default branch'
    got=$(fm_default_branch "$REPO"; printf '|')
    [ "$got" = "$expected"$'\n|' ] || fail 'default branch newline'
  done
  git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD || fail 'remove remote HEAD'
  git -C "$REPO" branch -m main || fail 'restore main'
  pass 'local main, master and remote default refs resolve with a newline'
}

test_current_checkout() {
  local current got rc
  for current in main feature detached unknown-default; do
    case "$current" in
      main) ;;
      feature) git -C "$REPO" checkout -qb feature || fail 'feature checkout' ;;
      detached) git -C "$REPO" checkout -q --detach || fail 'detach checkout' ;;
      unknown-default)
        git -C "$REPO" checkout -q feature || fail 'restore feature'
        git -C "$REPO" branch -D main >/dev/null || fail 'remove default'
        ;;
    esac
    got=$(fm_primary_tangle_branch "$REPO" 2>&1); rc=$?
    if [ "$current" = feature ]; then
      [ "$rc" -eq 0 ] && [ "$got" = feature ] || fail 'named feature branch detection'
      got=$(fm_primary_tangle_branch "$REPO"; printf '|')
      [ "$got" = feature$'\n|' ] || fail 'tangled branch newline'
    else
      [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'healthy or unresolved checkout must be silent'
    fi
  done
  got=$(fm_default_branch "$REPO" 2>/dev/null); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'missing default must fail silently'
  pass 'default, feature, detached and missing-default checkouts classify deterministically'
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
