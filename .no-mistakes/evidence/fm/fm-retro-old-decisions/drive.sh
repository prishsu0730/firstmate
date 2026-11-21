#!/usr/bin/env bash
# Live driver: runs the real bin/fm-wake-drain.sh against disposable lab homes.
set -u
WT=$1; BASEBIN=$2
LABS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-labs.XXXXXX")
lab() { local L; L=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$L" >/dev/null; echo "$L" >> "$LABS_FILE"; printf '%s' "$L"; }
drain() { local L=$1; shift; env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$L" "$@"; }
queue() { local L=$1; env -u FM_STATE_OVERRIDE FM_HOME="$L" bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$WT/bin/fm-wake-lib.sh" "$2" "$3" "$4"; }
now=$(date +%s)
sep() { printf '\n===== %s =====\n' "$*"; }

sep "S1 retro case: secondmate decision opened 8h ago, already shown once"
L=$(lab)
printf 'needs-decision [key=logo] [at=%s]: pick logo A or B (answer is in Decision Log)\n' $((now-28800)) > "$L/state/sm-design.status"
echo "--- drain 1 (first sight)"; drain "$L" "$WT/bin/fm-wake-drain.sh"
echo "--- drain 2 (empty queue, NEW code)"; drain "$L" "$WT/bin/fm-wake-drain.sh"
echo "--- drain 3 (immediately again, NEW code, cooldown)"; drain "$L" "$WT/bin/fm-wake-drain.sh"

sep "S1b same fixture on BASE code (before fix)"
L=$(lab)
printf 'needs-decision [key=logo] [at=%s]: pick logo A or B (answer is in Decision Log)\n' $((now-28800)) > "$L/state/sm-design.status"
drain "$L" "$BASEBIN/fm-wake-drain.sh" >/dev/null
echo "--- drain 2 (BASE code)"; drain "$L" "$BASEBIN/fm-wake-drain.sh"

sep "S2 young decision (30m) stays a count; ordinary drain with a queued wake"
L=$(lab)
printf 'needs-decision [key=copy] [at=%s]: pick headline\n' $((now-1800)) > "$L/state/sm-copy.status"
printf 'blocked [key=infra] [at=%s]: need staging creds\n' $((now-36000)) > "$L/state/sm-ops.status"
drain "$L" "$WT/bin/fm-wake-drain.sh" >/dev/null
queue "$L" signal other.status 'working: continuing'
echo "--- ordinary drain"; drain "$L" "$WT/bin/fm-wake-drain.sh"

sep "S3 cooldown ends: clock moved +4h01m, decision returns with new age"
mkdir -p "$L/clock"
printf '#!/usr/bin/env bash\nif [ "$1" = +%%s ]; then echo %s; else exec %s "$@"; fi\n' $((now+14460)) "$(command -v date)" > "$L/clock/date"; chmod +x "$L/clock/date"
echo "--- drain right now"; drain "$L" "$WT/bin/fm-wake-drain.sh"
echo "--- drain at +4h01m"; PATH="$L/clock:$PATH" drain "$L" "$WT/bin/fm-wake-drain.sh"

sep "S4 resolved decision never resurfaces"
L=$(lab)
printf 'needs-decision [key=logo] [at=%s]: pick logo\n' $((now-28800)) > "$L/state/sm-a.status"
drain "$L" "$WT/bin/fm-wake-drain.sh" >/dev/null
printf 'resolved [key=logo] [at=%s]: went with A\n' $((now-60)) >> "$L/state/sm-a.status"
echo "--- drain after resolve (expect nothing)"; drain "$L" "$WT/bin/fm-wake-drain.sh"; echo "[exit=$?]"

sep "S5 adversarial: 20 aged long decisions + 1 new; budget rotation"
L=$(lab)
pad=$(printf '%0200d' 0)
for i in $(seq -w 1 20); do printf 'needs-decision [key=c] [at=%s]: choice-%s %s\n' $((now-18000)) "$i" "$pad" > "$L/state/t$i.status"; done
FM_DRAIN_FULL_OPEN_DECISIONS=1 drain "$L" "$WT/bin/fm-wake-drain.sh" >/dev/null
printf 'needs-decision: brand new choice\n' > "$L/state/zz-new.status"
o1=$(drain "$L" "$WT/bin/fm-wake-drain.sh"); o2=$(drain "$L" "$WT/bin/fm-wake-drain.sh")
echo "drain A: new-first=$(grep -c 'brand new choice' <<<"$o1") aged-shown=$(grep -o 'choice-[0-9][0-9]' <<<"$o1" | sort -u | tr '\n' ' ')"
echo "drain A summary: $(grep 'unchanged\|omitted' <<<"$o1")"
echo "drain B aged-shown=$(grep -o 'choice-[0-9][0-9]' <<<"$o2" | sort -u | tr '\n' ' ')"
all=$( (grep -o 'choice-[0-9][0-9]' <<<"$o1"; grep -o 'choice-[0-9][0-9]' <<<"$o2") | sort -u | wc -l | tr -d ' ')
echo "distinct aged decisions shown across A+B: $all / 20"

sep "S6 adversarial: note with a tab keeps age and cooldown"
L=$(lab)
printf 'needs-decision [key=t] [at=%s]: choose A\tor B\n' $((now-18000)) > "$L/state/sm-tab.status"
drain "$L" "$WT/bin/fm-wake-drain.sh" >/dev/null
echo "--- drain 2 (tab shown as ^I)"; drain "$L" "$WT/bin/fm-wake-drain.sh" | sed $'s/\t/^I/g'
echo "--- drain 3 (cooldown)"; drain "$L" "$WT/bin/fm-wake-drain.sh"

n=0
while read -r L; do n=$((n+1)); "$WT/bin/fm-lab-home.sh" teardown "$L" >/dev/null 2>&1 || echo "teardown failed $L"; done < "$LABS_FILE"
echo; echo "labs torn down: $n"
trash "$LABS_FILE"
