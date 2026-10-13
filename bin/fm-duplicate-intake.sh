#!/usr/bin/env bash
# Refuse a second task for a change another open task already carries.
#
# This is a one-shot, read-only check that bin/fm-spawn.sh runs for a fresh ship
# spawn before any worker copy, endpoint, or launch brief exists. It reads this
# home's task records and local git only; it never fetches and never calls a forge.
#
# Usage: fm-duplicate-intake.sh <task-id> <project-dir> <brief> --state <state-dir>
#                               [--data <data-dir>] [--base-branch <branch>]
#                               [--supersedes <task>] [--allow-duplicate]
#   Exit 0 lets the spawn continue, possibly after printing warnings or a notice
#   on stderr. Exit 1 refuses the spawn and names the colliding task on stderr.
#   Exit 2 is a usage error.
#   On exit 0 stdout carries one line, commits=<full-sha>[,<full-sha>...], when
#   the instructions name commits that still count (below); bin/fm-spawn.sh and
#   bin/fm-promote.sh record it as commits= in the task's state/<id>.meta, which
#   is how a later task finds this one's claim before any branch holds it.
#
# What counts as a collision: a commit SHA named in the new task's instructions
# (the brief's "# Task" body; 7 to 40 hex characters of either case, bounded by
# non-word characters, compared as lowercase full SHAs) that
#   - resolves to a commit in the repository,
#   - is not already landed: an ancestor of the project's default branch tip
#     (origin's default branch, else the project's checked-out branch) never
#     counts, neither does an ancestor of the new task's own --base-branch
#     (origin/<branch>, else the project's local branch of that name: a stacked
#     task starts from the earlier task's commits, so naming one is its start
#     point, not a second claim on it), and neither does an ancestor of the other
#     task's own base branch (origin/<base_branch>, else the default), and
#   - is listed in another open task's recorded commits=, or is contained in that
#     task's recorded branch or recorded pr_head=. When the other task's base
#     cannot be resolved, recorded commits= are still compared; only the branch
#     and pr_head containment, which needs a base to rule out base commits, is
#     skipped.
# Hex that resolves to no commit, such as an epoch, a date, or a gate id, is
# ignored without a message.
#
# Which tasks are open: a state/<id>.meta of kind=ship for the same project,
# other than the new task, whose recorded PR has not been recorded merged
# (state/<id>.pr-poll-merge-notified). Teardown removes the record, so a torn
# down task is closed. A held task keeps its record and so still collides: close
# or hold it, then pass --supersedes. The new task's own id never collides with
# itself, so a retry, a relaunch, and promotion of the same id are never refused
# by their own earlier claim.
#
# Flags:
#   --base-branch <branch> is the branch the new task starts from and targets, when
#   it is not the default. Commits already on it are the task's starting point, so
#   they are neither a collision nor recorded as its claim. A task that starts from
#   another task's unmerged commit without naming that task's branch here cannot be
#   told apart from a second claim on it: pass --supersedes or --allow-duplicate.
#   --supersedes <task> names the task this one replaces. It excuses collisions
#   with that task only; a collision with any other task still refuses.
#   bin/fm-spawn.sh records the link as supersedes= in the new task's meta.
#   --allow-duplicate proceeds past every collision with a one-line notice.
#
# Looser similarity never refuses: when --data names the data directory and the
# first nonblank line of the new task's "## Captain's intent" equals another open
# same-project task's brief, ignoring case and whitespace, the check only prints
# a warning.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-duplicate-intake: %s\n' "$*" >&2
  exit 2
}

meta_get() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

physical_dir() {  # <dir>
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

# The first nonblank line of a brief's captain intent, lowercased with runs of
# whitespace collapsed. Empty when the brief has none.
intent_title() {  # <brief>
  fm_brief_task_heading_body "$1" "## Captain's intent" 2>/dev/null |
    awk 'NF { print tolower($0); exit }' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# Print "<repo>|<ref>" for the base a task's own commits are measured from, or
# nothing. A recorded base_branch= names origin/<branch>; otherwise origin's
# default branch; with no origin ref anywhere, the project's own checked-out
# branch (a local-only project lands on it), unless that is the task's branch.
task_base() {  # <task-repo> <project> <meta-file> <task-branch>
  local task_repo=$1 project=$2 meta=$3 branch=$4 base repo candidate
  base=$(meta_get "$meta" base_branch)
  for repo in "$task_repo" "$project"; do
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    if [ -n "$base" ]; then
      candidate=refs/remotes/origin/$base
      if git -C "$repo" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
        printf '%s|%s\n' "$repo" "$candidate"
        return 0
      fi
      continue
    fi
    candidate=$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
    for candidate in "$candidate" refs/remotes/origin/main refs/remotes/origin/master; do
      [ -n "$candidate" ] || continue
      if git -C "$repo" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
        printf '%s|%s\n' "$repo" "$candidate"
        return 0
      fi
    done
  done
  [ -z "$base" ] || return 0
  candidate=$(git -C "$project" symbolic-ref --quiet HEAD 2>/dev/null || true)
  if [ -n "$candidate" ] && [ "$candidate" != "refs/heads/$branch" ] &&
    git -C "$project" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
    printf '%s|%s\n' "$project" "$candidate"
  fi
  return 0
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi

NEW_ID=
PROJECT=
BRIEF=
STATE=
DATA=
SUPERSEDES=
BASE_BRANCH=
ALLOW=0
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state)
      [ "$#" -ge 2 ] || die "--state requires a value"
      STATE=$2
      shift 2
      ;;
    --data)
      [ "$#" -ge 2 ] || die "--data requires a value"
      DATA=$2
      shift 2
      ;;
    --base-branch)
      [ "$#" -ge 2 ] || die "--base-branch requires a value"
      BASE_BRANCH=$2
      shift 2
      ;;
    --supersedes)
      [ "$#" -ge 2 ] || die "--supersedes requires a value"
      SUPERSEDES=$2
      shift 2
      ;;
    --allow-duplicate)
      ALLOW=1
      shift
      ;;
    -*) die "unknown option $1" ;;
    *)
      POS+=("$1")
      shift
      ;;
  esac
done
[ "${#POS[@]}" -eq 3 ] || die "usage: fm-duplicate-intake.sh <task-id> <project-dir> <brief> --state <state-dir> [--data <data-dir>] [--base-branch <branch>] [--supersedes <task>] [--allow-duplicate]"
NEW_ID=${POS[0]}
PROJECT=${POS[1]}
BRIEF=${POS[2]}
[ -n "$STATE" ] || die "--state is required"
fm_task_id_creation_valid "$NEW_ID" || die "invalid task id '$NEW_ID'"
if [ -n "$SUPERSEDES" ]; then
  fm_task_id_creation_valid "$SUPERSEDES" || die "--supersedes needs a task id, got '$SUPERSEDES'"
  [ "$SUPERSEDES" != "$NEW_ID" ] || die "a task cannot supersede itself"
fi
[ -f "$BRIEF" ] || die "no brief at $BRIEF"
[ -d "$STATE" ] || exit 0
PROJECT_REAL=$(physical_dir "$PROJECT") || PROJECT_REAL=$PROJECT

# The SHAs the new task's instructions name, split on any non-word character so
# the extraction does not depend on a grep that understands \b. Either case is
# accepted and compared as lowercase.
task_text=$(fm_brief_heading_body "$BRIEF" "# Task")
[ -n "$task_text" ] || task_text=$(cat "$BRIEF")
shas=$(printf '%s\n' "$task_text" | tr -c '0-9A-Za-z_' '\n' | grep -xE '[0-9a-fA-F]{7,40}' | tr 'A-F' 'a-f' | sort -u || true)
new_title=$(intent_title "$BRIEF")

# The commits that still count: each named SHA that resolves to a commit and is
# not yet on the project's default branch tip or on the new task's own base
# branch. One "<sha>|<full-sha>" line each; <sha> is the text the instructions
# used, for messages.
claims=
default_base=$(task_base "$PROJECT" "$PROJECT" /dev/null "")
own_base=
if [ -n "$BASE_BRANCH" ]; then
  for ref in "refs/remotes/origin/$BASE_BRANCH" "refs/heads/$BASE_BRANCH"; do
    if git -C "$PROJECT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
      own_base=$ref
      break
    fi
  done
fi
for sha in $shas; do
  full=$(git -C "$PROJECT" rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null) || continue
  if [ -n "$default_base" ] &&
    git -C "${default_base%|*}" merge-base --is-ancestor "$full" "${default_base#*|}" 2>/dev/null; then
    continue
  fi
  if [ -n "$own_base" ] && git -C "$PROJECT" merge-base --is-ancestor "$full" "$own_base" 2>/dev/null; then
    continue
  fi
  claims="$claims$sha|$full"$'\n'
done

matches=
similar=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$id" != "$NEW_ID" ] || continue
  [ "$(meta_get "$meta" kind)" = ship ] || continue
  project=$(meta_get "$meta" project)
  [ -n "$project" ] && [ "$(physical_dir "$project" || true)" = "$PROJECT_REAL" ] || continue
  pr=$(meta_get "$meta" pr)
  if [ -n "$pr" ] && fm_pr_url_parse "$pr" &&
    fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    continue
  fi

  hit=
  if [ -n "$claims" ]; then
    held=",$(meta_get "$meta" commits),"
    repo=$(meta_get "$meta" worktree)
    if [ -z "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
      repo=$project
    fi
    branch=$(meta_get "$meta" branch)
    pr_head=$(meta_get "$meta" pr_head)
    base=$(task_base "$repo" "$project" "$meta" "$branch")
    while IFS='|' read -r sha full; do
      [ -n "$sha" ] || continue
      if [ -n "$base" ] && git -C "${base%|*}" merge-base --is-ancestor "$full" "${base#*|}" 2>/dev/null; then
        continue
      fi
      case "$held" in
        *",$full,"*)
          hit="$hit$id|$sha|its instructions name this commit"$'\n'
          continue
          ;;
      esac
      # Without a base there is no way to tell a base commit from the task's own
      # work, so containment is only judged when one resolves.
      [ -n "$base" ] || continue
      if [ -n "$branch" ]; then
        for ref in "refs/heads/$branch" "refs/remotes/origin/$branch"; do
          git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
          if git -C "$repo" merge-base --is-ancestor "$full" "$ref" 2>/dev/null; then
            hit="$hit$id|$sha|branch $branch"$'\n'
            continue 2
          fi
        done
      fi
      if fm_pr_head_valid "$pr_head" && git -C "$repo" rev-parse --verify --quiet "$pr_head^{commit}" >/dev/null 2>&1 &&
        git -C "$repo" merge-base --is-ancestor "$full" "$pr_head" 2>/dev/null; then
        hit="$hit$id|$sha|open pull request head ${pr_head:0:12} (${pr:-no url recorded})"$'\n'
      fi
    done <<EOF
$claims
EOF
  fi
  if [ -n "$hit" ]; then
    matches="$matches$hit"
    continue
  fi

  if [ -n "$new_title" ] && [ -n "$DATA" ] && [ "$id" != "$SUPERSEDES" ]; then
    brief_of="$DATA/$id/brief.md"
    if [ -f "$brief_of" ] && [ "$(intent_title "$brief_of")" = "$new_title" ]; then
      similar="$similar$id"$'\n'
    fi
  fi
done

if [ -n "$matches" ]; then
  refused=
  excused=
  while IFS='|' read -r id sha reason; do
    [ -n "$id" ] || continue
    if [ "$ALLOW" -eq 1 ] || [ "$id" = "$SUPERSEDES" ]; then
      excused="$excused$id carries $sha ($reason)"$'\n'
    else
      refused="$refused  $id already carries commit $sha ($reason)"$'\n'
    fi
  done <<EOF
$matches
EOF
  if [ -n "$refused" ]; then
    {
      printf 'error: spawn refused: the instructions for %s name a commit that another open task already carries, so a second task would open a second PR for one change:\n' "$NEW_ID"
      printf '%s' "$refused"
      printf '%s\n' "close or hold the earlier task and pass --supersedes <task> to record the replacement, or pass --allow-duplicate if both tasks really are separate work."
    } >&2
    exit 1
  fi
  if [ -n "$excused" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ "$ALLOW" -eq 1 ]; then
        printf 'notice: %s proceeds past a duplicate-work match under --allow-duplicate: %s\n' "$NEW_ID" "$line" >&2
      else
        printf 'notice: %s supersedes %s\n' "$NEW_ID" "$line" >&2
      fi
    done <<EOF
$excused
EOF
  fi
fi

if [ -n "$similar" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf 'warning: %s has the same captain intent as open task %s but names no shared commit, so the spawn continues; confirm it is not the same change (--supersedes <task> records a replacement)\n' "$NEW_ID" "$id" >&2
  done <<EOF
$similar
EOF
fi
if [ -n "$claims" ]; then
  printf 'commits=%s\n' "$(printf '%s' "$claims" | cut -d'|' -f2 | sort -u | paste -sd, -)"
fi
exit 0
