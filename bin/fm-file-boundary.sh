#!/usr/bin/env bash
# Compare the files a task changes with the task's allowed-file list.
# Usage: fm-file-boundary.sh check <task-id> [--pr <url> [--head <sha>]]
#        fm-file-boundary.sh recorded <task-id>
#   check compares the changed files with the list recorded for the task.
#   Without --pr the changed files are the committed branch changes in the
#   task's worktree (the `worktree=` in state/<id>.meta, else the current
#   directory): `git diff --name-only --no-renames <merge-base>...HEAD`, where
#   the base is origin/<base_branch=> from the same metadata, else origin/HEAD,
#   origin/main, or origin/master. A rename or deletion counts both paths,
#   and paths are read unquoted so they compare as the forge reports them.
#   With --pr the changed files are the live pull request's file list, read
#   from GitHub with every page and including a rename's previous path.
#   --head <sha> binds that read to a head the caller already verified: a live
#   head that differs is refused with exit 2, because the list would then
#   describe a commit nobody verified. It is only valid with --pr.
#   Exit 0: every changed file is in the list, or no list is recorded for the
#   task (a note says so and nothing is read, so a task without a boundary is
#   never touched). Exit 1: one or more changed files fall outside the list,
#   each named on stderr. Exit 2: the check could not be made - a usage error,
#   an unreadable base, file list, or head, or a forge this script cannot
#   read - because an unreadable boundary must not read as a pass.
#   recorded prints the list's path and exits 0 when the task has a list, exits
#   1 silently when it has none, and exits 2 when the task was briefed with a
#   list that cannot be read: a boundary that was recorded and then lost must
#   refuse, never read as "no boundary". bin/fm-pr-merge.sh uses it to decide
#   whether the merge-time refusal applies.
# The list is a task record: bin/fm-brief.sh --allowed-files copies it to
# <data>/<task-id>/allowed-files, one path or glob per line, already validated
# and stripped of blank and comment lines, and this script is the only reader
# of that path. The same scaffold writes a `File boundary: required` line into
# <data>/<task-id>/brief.md right after its `# Allowed files` heading, and only
# that pair counts, so a list that is later deleted or made unreadable
# is found missing rather than taken for a task that never had one; a task
# whose brief carries no such pair, or that has no brief, has no boundary. The
# record lives beside the brief rather than in state/<id>.meta because
# bin/fm-spawn.sh publishes that file fresh at every spawn and owns its field
# set, while the data directory is the task's private record that no CI job or
# no-mistakes step can read, which is why the merge-time check runs in
# fm-pr-merge.sh. A glob's `*` and `?` stay inside one directory; `**` crosses
# directories, and `**/` also matches no directory at all, so `docs/**/*.md`
# allows docs/a.md. Every other character, `[` included, is literal. Exact
# paths and globs are matched against repo-relative paths. A list entry names a
# file or a glob, not a directory: `docs/` matches only that literal path.
# Changed paths are read without splitting on newlines (git's -z output, and a
# JSON field per path from the forge), and a path that itself contains a
# newline is reported as outside the list, because no one-line entry can name it.
# Environment: FM_HOME, FM_DATA_OVERRIDE, and FM_STATE_OVERRIDE select the data
# and state directories exactly as for bin/fm-brief.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SUBCOMMAND=${1:-}
case "$SUBCOMMAND" in
  check|recorded) shift ;;
  *) die "usage: fm-file-boundary.sh check <task-id> [--pr <url> [--head <sha>]] | recorded <task-id>" ;;
esac
[ "$#" -ge 1 ] || die "$SUBCOMMAND needs a task id"
ID=$1
shift
fm_pr_task_id_valid "$ID" || die "invalid task id: $ID"

PR_URL=
HEAD=
if [ "$SUBCOMMAND" = recorded ]; then
  [ "$#" -eq 0 ] || die "recorded takes no arguments after the task id"
else
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr)
        [ -n "${2:-}" ] || die "--pr requires a pull request URL"
        PR_URL=$2
        shift 2
        ;;
      --head)
        [ -n "${2:-}" ] || die "--head requires a commit"
        HEAD=$2
        shift 2
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -z "$HEAD" ] || [ -n "$PR_URL" ] || die "--head applies only with --pr"
  # Validated before the list is looked up, so a malformed URL is an error even
  # for a task that has no boundary.
  [ -z "$PR_URL" ] || fm_pr_url_parse "$PR_URL" || die "invalid pull request URL: $PR_URL"
fi

LIST="$DATA/$ID/allowed-files"
BRIEF_FILE="$DATA/$ID/brief.md"
BOUNDARY_HEADING='# Allowed files'
BOUNDARY_MARKER='File boundary: required'

# Whether the task has a boundary, and if it does whether it can be read:
# BOUNDARY is list (read it), none (no boundary), or lost (one was recorded and
# cannot be read, with the reason in BOUNDARY_WHY).
BOUNDARY=none
BOUNDARY_WHY=
resolve_boundary() {
  local line prev=
  if [ -e "$LIST" ] || [ -L "$LIST" ]; then
    if [ -f "$LIST" ] && [ -r "$LIST" ]; then
      BOUNDARY=list
    else
      BOUNDARY=lost
      BOUNDARY_WHY="the allowed-file list for task $ID is not a readable file: $LIST"
    fi
    return 0
  fi
  if [ -d "$DATA/$ID" ] && [ ! -x "$DATA/$ID" ]; then
    BOUNDARY=lost
    BOUNDARY_WHY="the task data directory for task $ID cannot be read, so its allowed-file list cannot be found: $DATA/$ID"
    return 0
  fi
  [ -e "$BRIEF_FILE" ] || [ -L "$BRIEF_FILE" ] || return 0
  if [ ! -f "$BRIEF_FILE" ] || [ ! -r "$BRIEF_FILE" ]; then
    BOUNDARY=lost
    BOUNDARY_WHY="the brief of task $ID is not a readable file, so whether it carried an allowed-file list cannot be told: $BRIEF_FILE"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$prev" = "$BOUNDARY_HEADING" ] && [ "$line" = "$BOUNDARY_MARKER" ]; then
      BOUNDARY=lost
      BOUNDARY_WHY="task $ID was briefed with an allowed-file list but $LIST is missing"
      return 0
    fi
    prev=$line
  done < "$BRIEF_FILE"
  return 0
}
resolve_boundary

case "$BOUNDARY" in
  list) ;;
  none)
    [ "$SUBCOMMAND" = recorded ] && exit 1
    printf 'no boundary recorded for task %s; every file is allowed\n' "$ID"
    exit 0
    ;;
  *) die "$BOUNDARY_WHY" ;;
esac
if [ "$SUBCOMMAND" = recorded ]; then
  printf '%s\n' "$LIST"
  exit 0
fi

# Resolve the changed files into $CHANGED_FILE, one NUL-terminated record per
# path. A newline is a legal file-name character, so no step below may treat the
# list as lines. Records from a local branch are bare paths; records from a pull
# request are `P:<path>`, or `N:` for a path that contains a newline, which the
# forge read replaces before the name can reach a line-oriented stream.
CHANGED_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-file-boundary.XXXXXX") || die "cannot create a scratch file"
trap 'rm -f "$CHANGED_FILE"' EXIT
CHANGED_FROM=branch
meta_get() {  # <key>
  sed -n "s/^$1=//p" "$STATE/$ID.meta" 2>/dev/null | tail -n 1
}

changed_from_branch() {
  local wt base candidate ref merge_base
  wt=$(meta_get worktree)
  [ -n "$wt" ] || wt=$PWD
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 \
    || die "cannot read the branch changes: $wt is not a git worktree"
  base=$(meta_get base_branch)
  ref=
  if [ -n "$base" ]; then
    candidate=refs/remotes/origin/$base
    git -C "$wt" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1 && ref=$candidate
  else
    candidate=$(git -C "$wt" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
    for candidate in "$candidate" refs/remotes/origin/main refs/remotes/origin/master; do
      [ -n "$candidate" ] || continue
      if git -C "$wt" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
        ref=$candidate
        break
      fi
    done
  fi
  [ -n "$ref" ] || die "cannot find the base branch to compare against in $wt${base:+ (base_branch=$base)}"
  merge_base=$(git -C "$wt" merge-base "$ref" HEAD 2>/dev/null) \
    || die "cannot find a merge base between $ref and HEAD in $wt"
  git -C "$wt" diff -z --no-renames --name-only "$merge_base...HEAD" > "$CHANGED_FILE" \
    || die "cannot list the changes since $merge_base in $wt"
}

changed_from_pr() {
  local live_head pr_files
  [ "$FM_PR_PROVIDER" = github ] \
    || die "the file boundary cannot read a $FM_PR_PROVIDER change's file list; only GitHub pull requests are supported"
  command -v gh >/dev/null 2>&1 || die "reading a pull request's files requires gh on PATH"
  if [ -n "$HEAD" ]; then
    live_head=$(gh pr view "$FM_PR_URL" --json headRefOid -q .headRefOid 2>/dev/null) \
      || die "could not read the head of $FM_PR_URL"
    [ "$live_head" = "$HEAD" ] \
      || die "the head of $FM_PR_URL is $live_head, not the verified $HEAD; its file list was not checked"
  fi
  # Every page, and both paths of a rename: the old path is a file this change
  # touched even though it no longer exists.
  CHANGED_FROM="pr"
  pr_files=$(gh api --paginate "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/files" \
    --jq '.[] | (.filename, (.previous_filename // empty)) | if test("\n") then "N:" else "P:" + . end' 2>/dev/null) \
    || die "could not read the changed files of $FM_PR_URL"
  printf '%s' "$pr_files" | tr '\n' '\0' > "$CHANGED_FILE"
}

if [ -n "$PR_URL" ]; then
  changed_from_pr
else
  changed_from_branch
fi

# The list entries as anchored extended regexes: `**/` is any run of whole
# directories including none, any other `**` is anything, `*` and `?` never
# match a `/`, and every other character matches itself.
glob_regex() {  # <glob>
  local glob=$1 re='' c i=0
  while [ "$i" -lt "${#glob}" ]; do
    c=${glob:i:1}
    case "$c" in
      '*')
        if [ "${glob:i+1:1}" = '*' ]; then
          if [ "${glob:i+2:1}" = / ]; then
            re="$re(.*/)?"
            i=$((i + 3))
          else
            re="$re.*"
            i=$((i + 2))
          fi
          continue
        fi
        re="${re}[^/]*"
        ;;
      '?') re="${re}[^/]" ;;
      '.'|'['|']'|'^'|'$'|'+'|'('|')'|'{'|'}'|'|'|\\) re="$re\\$c" ;;
      *) re="$re$c" ;;
    esac
    i=$((i + 1))
  done
  printf '^%s$' "$re"
}

PATTERNS=()
while IFS= read -r pattern || [ -n "$pattern" ]; do
  [ -n "$pattern" ] || continue
  PATTERNS+=("$(glob_regex "$pattern")")
done < "$LIST"

path_allowed() {  # <path>
  local re
  for re in ${PATTERNS[@]+"${PATTERNS[@]}"}; do
    [[ $1 =~ $re ]] && return 0
  done
  return 1
}

total=0
outside=
while IFS= read -r -d '' record || [ -n "$record" ]; do
  total=$((total + 1))
  file=$record
  newline_path=0
  if [ "$CHANGED_FROM" = pr ]; then
    case "$record" in
      P:*) file=${record#P:} ;;
      *) newline_path=1 ;;
    esac
  fi
  case "$file" in
    *$'\n'*) newline_path=1 ;;
  esac
  if [ "$newline_path" -eq 1 ]; then
    outside="${outside}  - (a changed file whose name contains a newline; no list entry can name it)
"
  elif ! path_allowed "$file"; then
    outside="${outside}  - $file
"
  fi
done < "$CHANGED_FILE"

if [ -n "$outside" ]; then
  printf 'error: file boundary for task %s: these changed files are outside the allowed list %s:\n%s' \
    "$ID" "$LIST" "$outside" >&2
  exit 1
fi
printf 'file boundary ok for task %s: %s changed file(s), all within the allowed list\n' "$ID" "$total"
