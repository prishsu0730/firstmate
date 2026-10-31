# shellcheck shell=bash
# Away spawn spend accounting using the existing reconciled crew-state owner.
# Usage: fm_worker_spend_parked <script-dir> <state-dir> <task-id>
# Only a reconciled parked, paused, or done verdict releases spend capacity.
# A live pipeline overrides an old pause in fm-crew-state.sh; failed reads,
# conflicts, blocked work, and unknown liveness continue to count.
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
fm_worker_spend_parked() {
  local verdict
  verdict=$(FM_STATE_OVERRIDE="$2" FM_CREW_STATE_NO_FORGE=1 fm_run_timed 15 "$1/fm-crew-state.sh" "$3" 2>/dev/null) || return 1
  case "$verdict" in
    'state: parked '*|'state: paused '*|'state: done '*) return 0 ;;
    *) return 1 ;;
  esac
}
