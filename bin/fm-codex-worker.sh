#!/usr/bin/env bash
# Codex launch-owned process-exit proof, independent of semantic busy hooks.
# Usage: fm-codex-worker.sh run <state> <id> <spawn-gen> <command> [args...]
#        fm-codex-worker.sh released <state> <id>
#        fm-codex-worker.sh invalidate <state> <id>
# Only the synchronous successful return of the launched command publishes a
# receipt. A killed wrapper, failed command, old launch, unreadable record, or
# absent completion artifact supplies no release proof. The receipt is not a
# delivery verdict and never authorizes cleanup. Legacy launches stay counted.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

action=${1:-} state=${2:-} id=${3:-}
case "$id" in ''|.*|*[!a-zA-Z0-9._-]*) exit 1 ;; esac
meta="$state/$id.meta"
[ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || exit 1
[ "$(fm_meta_get "$meta" harness)" = codex ] || exit 1
gen=$(fm_meta_get "$meta" spawn_gen)
case "$gen" in ''|*[!a-zA-Z0-9_.-]*) exit 1 ;; esac
# Keep proof in the existing task temp root so normal teardown owns its life.
# No new teardown path or worktree write is needed.
tasktmp=$(fm_meta_get "$meta" tasktmp)
[ -n "$tasktmp" ] && [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] && [ -O "$tasktmp" ] || exit 1
writable=$(find "$tasktmp" -prune \( -perm -g=w -o -perm -o=w \) -print) || exit 1
[ -z "$writable" ] || exit 1
receipt="$tasktmp/codex-exited.$gen"
case "$action" in
  invalidate)
    [ ! -L "$receipt" ] || exit 1
    # An empty receipt cannot release capacity, even if the done declaration
    # survives a resume. Only a fresh successful wrapped command restores it.
    [ ! -e "$receipt" ] || : > "$receipt"
    ;;
  run)
    [ "$#" -ge 5 ] && [ "$4" = "$gen" ] || exit 1
    # Invalidate a previous receipt before executing anything, including a
    # repeated invocation of this same launch command.
    [ ! -L "$receipt" ] || exit 1
    : > "$receipt" || exit 1
    shift 4
    "$@"
    rc=$?
    [ "$rc" = 0 ] || exit "$rc"
    [ "$(fm_meta_get "$meta" spawn_gen)" = "$gen" ] || exit 1
    [ ! -L "$receipt" ] || exit 1
    printf '%s\n' "$gen" > "$receipt"
    ;;
  released)
    [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ -r "$receipt" ] || exit 1
    [ "$(cat "$receipt")" = "$gen" ] || exit 1
    [ -f "$state/$id.status" ] && [ ! -L "$state/$id.status" ] && [ -r "$state/$id.status" ] || exit 1
    kind=$(fm_meta_get "$meta" kind)
    line=$(status_current_line "$state/$id.status" "$kind") || exit 1
    [ "$(status_line_verb "$line")" = "done" ] || exit 1
    case "$kind" in
      scout)
        report="${state%/*}/data/$id/report.md"
        [ -f "$report" ] && [ ! -L "$report" ] && [ -r "$report" ] && [ -s "$report" ] || exit 1
        ;;
      ship)
        pr=$(fm_meta_get "$meta" pr)
        case "$pr" in https://*) ;; *) exit 1 ;; esac
        case "$(status_line_note "$line")" in *"$pr"*) ;; *) exit 1 ;; esac
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
