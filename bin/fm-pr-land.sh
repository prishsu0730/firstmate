#!/usr/bin/env bash
# Land a recorded PR by URL through the existing guarded merge entrypoint.
# Usage: fm-pr-land.sh <pr-url> [fm-pr-merge.sh options and forge arguments]
# Searches this home's task records and the registered local home tree using
# fm_local_firstmate_state_dirs. Remote homes are not searched. Unknown,
# ambiguous, unreadable, and unsafe ownership refuses without a merge attempt.
# Resolving ownership grants no merge authority and skips no merge guard.
# The selected home's stock data/config paths replace ambient overrides; the
# guarded merge re-reads task identity and all live forge and authority gates.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
case "${1:-}" in
  -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac
[ "$#" -gt 0 ] && fm_pr_url_parse "$1" || {
  echo 'error: a valid PR URL is required' >&2; exit 2;
}
URL=$FM_PR_URL
shift
fm_local_firstmate_state_dirs "$STATE" || {
  printf 'error: cannot resolve PR ownership: %s\n' "$FM_LOCAL_FIRSTMATE_ERROR" >&2
  exit 1
}
owner_home= owner_state= owner_id=
for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
  [ -e "$state" ] || [ -L "$state" ] || continue
  [ -d "$state" ] && [ ! -L "$state" ] && [ -r "$state" ] && [ -x "$state" ] || {
    printf 'error: unsafe or unreadable state directory: %s\n' "$state" >&2; exit 1;
  }
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || {
      printf 'error: unsafe or unreadable task metadata: %s\n' "$meta" >&2; exit 1;
    }
    kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
    [ "$kind" != secondmate ] || continue
    pr=$(sed -n 's/^pr=//p' "$meta" | tail -1)
    [ "$pr" = "$URL" ] || continue
    id=${meta##*/}; id=${id%.meta}
    fm_pr_task_id_valid "$id" || { echo 'error: invalid owning task ID' >&2; exit 1; }
    [ -z "$owner_id" ] || {
      printf 'error: ambiguous ownership for %s; multiple task records claim it\n' "$URL" >&2
      exit 1
    }
    owner_id=$id owner_state=$state owner_home=${state%/state}
    [ "$state" != "$STATE" ] || owner_home=$FM_HOME
  done
done
[ -n "$owner_id" ] || {
  printf 'error: no recorded local task owns %s; remote homes require their own guarded landing\n' "$URL" >&2
  exit 1
}
printf 'resolved: %s belongs to task %s in %s\n' "$URL" "$owner_id" "$owner_home"
exec env -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$owner_home" FM_STATE_OVERRIDE="$owner_state" \
  "$SCRIPT_DIR/fm-pr-merge.sh" "$owner_id" "$URL" "$@"
