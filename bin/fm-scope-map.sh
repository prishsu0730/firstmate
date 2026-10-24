#!/usr/bin/env bash
# fm-scope-map.sh - list a brief's scope items and check a worker's scope map.
#
# Usage: fm-scope-map.sh items <brief>
#        fm-scope-map.sh check <brief> <scope-map> [<worktree> [<base-branch>]]
#   items prints `KEY<TAB>text` for every numbered or bulleted item under the
#   brief's `## Captain's intent` and `## Firstmate spec`.
#   check prints one line per uncovered item and exits 1 when any is; <worktree>
#   defaults to the current git worktree. A brief without the `# Scope map`
#   section is never checked.
# bin/fm-scope-map-lib.sh owns the contract; bin/fm-dod-lib.sh applies it to a
# ship `done:`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-scope-map-lib.sh
. "$SCRIPT_DIR/fm-scope-map-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  items)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    fm_scope_map_items "$2" ;;
  check)
    [ "$#" -ge 3 ] && [ "$#" -le 5 ] || { usage >&2; exit 2; }
    wt=${4:-$(git rev-parse --show-toplevel 2>/dev/null || true)}
    if fm_scope_map_problems "$2" "$3" "$wt" "${5:-}"; then
      echo "scope map complete"
    else
      exit 1
    fi ;;
  *) usage >&2; exit 2 ;;
esac
