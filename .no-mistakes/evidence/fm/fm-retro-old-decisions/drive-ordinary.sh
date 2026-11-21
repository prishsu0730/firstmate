#!/usr/bin/env bash
# Live driver (rerun of S2/S3): ordinary drain with a queued wake for a status
# file that really exists, as the watcher produces it.
set -u
WT=$1
L=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$L" >/dev/null
drain() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$L" "$@"; }
queue() { env -u FM_STATE_OVERRIDE FM_HOME="$L" bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$WT/bin/fm-wake-lib.sh" "$1" "$2" "$3"; }
now=$(date +%s)
sep() { printf '\n===== %s =====\n' "$*"; }

sep "S2 ordinary drain: 10h-old decision returns with age, 30m-old one stays a count"
printf 'needs-decision [key=copy] [at=%s]: pick headline\n' $((now-1800)) > "$L/state/sm-copy.status"
printf 'blocked [key=infra] [at=%s]: need staging creds\n' $((now-36000)) > "$L/state/sm-ops.status"
echo "--- drain 1 (first sight)"; drain "$WT/bin/fm-wake-drain.sh" 2>/dev/null
printf 'working [at=%s]: continuing\n' "$now" > "$L/state/other.status"
queue signal other.status 'working: continuing'
echo "--- drain 2 (ordinary, one queued signal wake)"; drain "$WT/bin/fm-wake-drain.sh" 2>/dev/null
echo "--- drain 3 (empty queue right after: cooldown)"; drain "$WT/bin/fm-wake-drain.sh" 2>/dev/null

sep "S3 clock moved +4h01m: aged decision returns again with its new age"
mkdir -p "$L/clock"
printf '#!/usr/bin/env bash\nif [ "$1" = +%%s ]; then echo %s; else exec %s "$@"; fi\n' $((now+14460)) "$(command -v date)" > "$L/clock/date"; chmod +x "$L/clock/date"
PATH="$L/clock:$PATH" drain "$WT/bin/fm-wake-drain.sh" 2>/dev/null

"$WT/bin/fm-lab-home.sh" teardown "$L" >/dev/null 2>&1 && echo && echo "lab torn down"
