#!/usr/bin/env bash
# Live driver (rerun of S6): an aged decision whose note holds a tab.
set -u
WT=$1
L=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$L" >/dev/null
drain() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$L" "$@"; }
now=$(date +%s)
printf '\n===== S6 adversarial: note with a tab keeps age and cooldown =====\n'
printf 'needs-decision [key=t] [at=%s]: choose A\tor B\n' $((now-18000)) > "$L/state/sm-tab.status"
echo "--- drain 1 (first sight)"; drain "$WT/bin/fm-wake-drain.sh" 2>/dev/null | sed $'s/\t/^I/g'
echo "--- drain 2 (aged, tab shown as ^I)"; drain "$WT/bin/fm-wake-drain.sh" 2>/dev/null | sed $'s/\t/^I/g'
echo "--- drain 3 (cooldown)"; drain "$WT/bin/fm-wake-drain.sh" 2>/dev/null
"$WT/bin/fm-lab-home.sh" teardown "$L" >/dev/null 2>&1 && echo && echo "lab torn down"
