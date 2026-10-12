#!/usr/bin/env bash
# Live drive of bin/fm-procevent.sh + the Lavish adapter in a disposable lab home.
# Usage: live-drive.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
export FM_HOME="$LAB" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
trap 'bin/fm-procevent.sh sweep-home >/dev/null 2>&1; pkill -f "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
PE=bin/fm-procevent.sh
INBOX="$LAB/state/procevent-inbox"
step() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

# Real-shaped Lavish captures (structure of real board captures, neutral text).
cat > "$LAB/expanded.toon" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[3]:
  - uid: "1"
    prompt: "Keep this option, it reads best"
    selector: "table > tbody > tr:nth-of-type(2) > td:nth-of-type(1)"
    tag: td
    text: Row one cell
    target:
      type: table-cell
      selector: "table > tbody > tr:nth-of-type(2) > td:nth-of-type(1)"
      rowLabel: Nested row label
      columnLabel: ""
      text: Nested target text
  - uid: "4"
    prompt: "Shorten this heading, quoting \"1x\""
    selector: section#v-a
    tag: section
    text: Section A heading
  - uid: ""
    prompt: "Still reviewing, more later"
    selector: ""
    tag: message
    text: Freeform message
next_step: "Apply the requested changes."
EOF
printf 'session:\n  file: /a.html\n  status: feedback\nprompts: []\nartifact_failures[1]{kind,detail,severity}:\n  artifact-asset-unavailable,an image could not load,fatal\n' > "$LAB/inline-empty.toon"

mksource() {  # <name> <toon-file>
  printf '#!/usr/bin/env bash\ncat %q\n' "$2" > "$LAB/$1.sh"; chmod +x "$LAB/$1.sh"
}
# The home's feedback-ledger recorder: appends the structured Lavish read to a
# ledger, and notes whether the capture was already announced when it ran.
recorder() {  # <extra-body>
  cat > "$LAB/config/procevent-recorder" <<EOF
#!/usr/bin/env bash
ann=no; grep -qF "procevent \$1 \$2 " "$LAB/state/.wake-queue" 2>/dev/null && ann=yes
{ printf -- '--- record %s %s (announced-before-record=%s)\n' "\$2" "\$3" "\$ann"
  "$WT/bin/fm-procevent-lavish.sh" read "\$3"; } >> "$LAB/data/feedback-ledger.md"
$1
EOF
  chmod 0700 "$LAB/config/procevent-recorder"
}

step "S1 expanded-list feedback lands in the ledger before announcement; handled succeeds"
recorder 'exit 0'
mksource s1 "$LAB/expanded.toon"
SID=lavish-live00000000000001
run $PE register lavish $SID -- "$LAB/s1.sh"
run $PE start $SID
echo "--- inbox files:"; ls -1 "$INBOX" | grep "$SID"
echo "--- wake queue:"; cat "$LAB/state/.wake-queue"
echo "--- ledger:"; cat "$LAB/data/feedback-ledger.md"
run $PE handled $SID 1

step "S2 failing recorder: visible failure, wake still sent, handled refused, fix + record, then handled"
recorder 'echo "ledger disk full" >&2; exit 1'
mksource s2 "$LAB/expanded.toon"
SID=lavish-live00000000000002
run $PE register lavish $SID -- "$LAB/s2.sh"
run $PE start $SID
echo "--- .recorder-failed:"; cat "$INBOX/$SID.1.recorder-failed"
echo "--- .recorder-log:"; cat "$INBOX/$SID.1.recorder-log"
echo "--- wake queue line:"; grep "$SID" "$LAB/state/.wake-queue"
run $PE handled $SID 1
echo "--- .handled exists? $( [ -e "$INBOX/$SID.1.handled" ] && echo yes || echo no )"
step "S2b adversarial: --unrecorded bypass is gone; a symlinked .recorded marker does not pass the gate"
run $PE handled $SID 1 --unrecorded "just let it through"
ln -s "$LAB/expanded.toon" "$INBOX/$SID.1.recorded"
run $PE handled $SID 1
rm -f "$INBOX/$SID.1.recorded"
step "S2c fix the recorder, retry with record, then acknowledge"
recorder 'exit 0'
run $PE record $SID 1
echo "--- .recorder-failed still there? $( [ -e "$INBOX/$SID.1.recorder-failed" ] && echo yes || echo no )"
run $PE handled $SID 1

step "S3 hung recorder is bounded by FM_PROCEVENT_RECORDER_TIMEOUT"
recorder 'sleep 311'
mksource s3 "$LAB/expanded.toon"
SID=lavish-live00000000000003
run $PE register lavish $SID -- "$LAB/s3.sh"
t0=$(date +%s); FM_PROCEVENT_RECORDER_TIMEOUT=2 run $PE start $SID; echo "--- start took $(( $(date +%s) - t0 ))s"
sleep 1; echo "--- leftover 'sleep 311' processes: $(pgrep -f 'sleep 311' | wc -l | tr -d ' ')"
grep "$SID" "$LAB/state/.wake-queue"
run $PE handled $SID 1

step "S4 inline-empty prompts: [] with a fatal artifact failure"
recorder 'exit 0'
mksource s4 "$LAB/inline-empty.toon"
SID=lavish-live00000000000004
run $PE register lavish $SID -- "$LAB/s4.sh"
run $PE start $SID
run bin/fm-procevent-lavish.sh read "$INBOX/$SID.1.result"
run $PE handled $SID 1

step "S5 expanded-list read counts"
run bin/fm-procevent-lavish.sh read "$INBOX/lavish-live00000000000001.1.result"

step "S6 no recorder configured: unchanged behavior"
rm -f "$LAB/config/procevent-recorder"
mksource s6 "$LAB/expanded.toon"
SID=lavish-live00000000000006
run $PE register lavish $SID -- "$LAB/s6.sh"
run $PE start $SID
run $PE handled $SID 1
run $PE record $SID 1
echo; echo "lab: $LAB (removed on exit)"
