#!/usr/bin/env bash
# Catch commit messages that address the operator before they are pushed.
# Usage: fm-commit-address-check.sh [<base-ref>]
#   Checks every commit message (subject and body) in <base-ref>..HEAD of the
#   current directory's git copy against the word list owned by
#   bin/fm-commit-address-lib.sh, the same list bin/fm-pr-merge.sh enforces.
#   <base-ref> defaults to origin/HEAD, then origin/main, origin/master, main,
#   master, whichever resolves first.
#   Exit 0: no commit addresses the operator. Exit 1: one or more do; each is
#   named on stderr by short SHA and subject, and a local
#   `git commit --amend` or `git rebase -i` fixes it before push. Exit 2: the
#   check could not run, because an unreadable range must not read as a pass.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-commit-address-lib.sh
. "$SCRIPT_DIR/fm-commit-address-lib.sh"

[ "$#" -le 1 ] || { echo "usage: fm-commit-address-check.sh [<base-ref>]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git copy" >&2; exit 2; }

base=${1:-}
if [ -z "$base" ]; then
  for cand in origin/HEAD origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then base=$cand; break; fi
  done
fi
[ -n "$base" ] || { echo "error: no base ref found; pass one" >&2; exit 2; }
git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
  || { echo "error: base ref $base does not resolve" >&2; exit 2; }

shas=$(git rev-list "$base..HEAD") || { echo "error: could not list commits in $base..HEAD" >&2; exit 2; }
bad=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  msg=$(git show -s --format=%B "$sha") || { echo "error: could not read commit $sha" >&2; exit 2; }
  # shellcheck disable=SC2016 # jq, not the shell, expands $re.
  if printf '%s' "$msg" | jq -Rse --arg re "$FM_COMMIT_ADDRESS_RE" 'test($re; "i")' >/dev/null; then
    printf '%s %s\n' "${sha:0:8}" "$(printf '%s' "$msg" | head -n1 | jq -Rs .)" >&2
    bad=1
  fi
done <<<"$shas"
if [ "$bad" -ne 0 ]; then
  echo "error: commit messages above contain a direct address; reword them with a local amend or rebase before pushing" >&2
  exit 1
fi
exit 0
