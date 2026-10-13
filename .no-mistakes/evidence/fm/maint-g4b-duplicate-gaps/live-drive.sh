#!/usr/bin/env bash
# Live drive of G4b: real fm-promote.sh / fm-duplicate-intake.sh / fm-spawn.sh in a marked lab home.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
G=(-c user.name=Lab -c user.email=lab@example.invalid)
P=$LAB/projsrc/demo; O=$LAB/projsrc/origin.git
git init -q --bare -b main "$O"; git init -q -b main "$P"
echo base > "$P/a.txt"; git -C "$P" add a.txt; git -C "$P" "${G[@]}" commit -qm base
git -C "$P" remote add origin "$O"; git -C "$P" push -q origin main; git -C "$P" fetch -q origin
git -C "$P" remote set-head origin main >/dev/null
tree=$(git -C "$P" rev-parse 'main^{tree}')
mk() { git -C "$P" "${G[@]}" commit-tree "$tree" -p main -m "$1"; }
X=$(mk "floating X"); Y=$(mk "floating Y"); Z=$(mk "floating Z")
UX=$(printf '%s' "$X" | tr a-f A-F)
scout() { # id intent
  cat > "$LAB/state/$1.meta" <<M
window=firstmate:fm-$1
endpoint_task_id=$1
worktree=$LAB/wt-$1
project=$P
harness=claude
kind=scout
mode=scout
yolo=off
M
  mkdir -p "$LAB/data/$1"; printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\nlive drive\n' "$2" > "$LAB/data/$1/brief.md"
}
promote() { "$ROOT/bin/fm-promote.sh" "$@" --mode no-mistakes --yolo off 2>&1; echo "exit=$?"; }
show() { echo "  [$1.meta] $(grep -E '^(kind|commits|supersedes)=' "$LAB/state/$1.meta" | tr '\n' ' ')"; }
echo "lab home: $LAB"; echo "X=$X"; echo "Y=$Y"; echo "Z=$Z"

echo; echo "== S1 promote scout-a naming X in UPPERCASE, no branch holds X yet"
scout scout-a "Ship the fix in commit $UX as its own change."
promote scout-a | sed 's/^/  /'; show scout-a

echo; echo "== S2 promote scout-b naming X lowercase abbreviated (${X:0:9}) -> must refuse, nothing changed"
scout scout-b "Redo the change from ${X:0:9} under a different title."
before=$(shasum "$LAB/state/scout-b.meta")
promote scout-b | sed 's/^/  /'; show scout-b
[ "$before" = "$(shasum "$LAB/state/scout-b.meta")" ] && echo "  scout-b.meta byte-identical after refusal: yes"

echo; echo "== S2b retry same refused promotion -> still refused"
promote scout-b | tail -2 | sed 's/^/  /'

echo; echo "== S3 fm-duplicate-intake (spawn guard) for a fresh ship brief naming X -> refuse"
mkdir -p "$LAB/data/new-c"; printf '# Task\n## Captain'"'"'s intent\nPort %s to the new API.\n' "${X:0:7}" > "$LAB/data/new-c/brief.md"
"$ROOT/bin/fm-duplicate-intake.sh" new-c "$P" "$LAB/data/new-c/brief.md" --state "$LAB/state" --data "$LAB/data" 2>&1 | sed 's/^/  /'; echo "  exit=${PIPESTATUS[0]}"

echo; echo "== S4 distinct work: promote scout-d naming Y (plus a non-commit hex deadbeef1234 and a landed base commit) -> allowed"
scout scout-d "Ship commit $Y. Log line: gate deadbeef1234. Built on $(git -C "$P" rev-parse main)."
promote scout-d | sed 's/^/  /'; show scout-d

echo; echo "== S5 --supersedes scout-a lets scout-b through and records the link"
promote scout-b --supersedes scout-a | head -3 | sed 's/^/  /'; show scout-b

echo; echo "== S6 concurrent: two scouts naming Z promoted at the same instant -> exactly one owner"
scout race-1 "Ship commit ${Z:0:10}."; scout race-2 "Also ship $(printf '%s' "$Z" | tr a-f A-F)."
( promote race-1 > "$LAB/r1.out" ) & ( promote race-2 > "$LAB/r2.out" ) & wait
for r in race-1 race-2; do n=${r#race-}; echo "  $r: $(tail -1 "$LAB/r$n.out") $(grep -E '^error' "$LAB/r$n.out" | head -1)"; show $r; done
echo "  task records claiming Z: $(grep -l "^commits=.*$Z" "$LAB"/state/*.meta | wc -l | tr -d ' ')"

echo; echo "== S7 real fm-spawn.sh fresh ship naming Z inside a lab tmux pane -> refused before any record"
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
mkdir -p "$LAB/data/new-e"; printf '# Task\n## Captain'"'"'s intent\nRe-land commit %s.\n\n## Firstmate spec\nlive\n' "${Z:0:8}" > "$LAB/data/new-e/brief.md"
echo claude > "$LAB/config/crew-harness"
TMUX_TMPDIR="$TD" tmux -L fm-lab new-session -d -s primary -c "$ROOT" -x 200 -y 50 -e FM_HOME="$LAB"
TMUX_TMPDIR="$TD" tmux -L fm-lab send-keys -t primary "env -u NO_MISTAKES_GATE FM_HOME=$LAB bin/fm-spawn.sh new-e $P --mode no-mistakes --yolo off > $LAB/spawn.out 2>&1; echo spawn-exit=\$? >> $LAB/spawn.out" Enter
for i in $(seq 60); do grep -q spawn-exit "$LAB/spawn.out" 2>/dev/null && break; sleep 1; done
sed 's/^/  /' "$LAB/spawn.out"
echo "  new-e.meta exists: $([ -e "$LAB/state/new-e.meta" ] && echo yes || echo no); launch-brief exists: $([ -e "$LAB/data/new-e/launch-brief.md" ] && echo yes || echo no)"
echo "  lab tmux windows: $(TMUX_TMPDIR="$TD" tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name}' | tr '\n' ' ')"
TMUX_TMPDIR="$TD" tmux -L fm-lab kill-server
"$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
