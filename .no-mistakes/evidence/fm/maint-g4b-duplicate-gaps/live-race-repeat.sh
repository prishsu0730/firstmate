#!/usr/bin/env bash
# Repeat: 3 scouts naming one commit promoted at once, 5 rounds, real fm-promote.sh in a lab home.
set -u; ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"; "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB; unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_STATE_OVERRIDE FM_DATA_OVERRIDE
G=(-c user.name=Lab -c user.email=lab@example.invalid); P=$LAB/demo; O=$LAB/origin.git
git init -q --bare -b main "$O"; git init -q -b main "$P"; echo b > "$P/a"; git -C "$P" add a; git -C "$P" "${G[@]}" commit -qm b
git -C "$P" remote add origin "$O"; git -C "$P" push -q origin main; git -C "$P" fetch -q origin; git -C "$P" remote set-head origin main >/dev/null
tree=$(git -C "$P" rev-parse 'main^{tree}')
for round in 1 2 3 4 5; do
  C=$(git -C "$P" "${G[@]}" commit-tree "$tree" -p main -m "round $round")
  for k in 1 2 3; do id=r$round-$k
    printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\nmode=scout\nyolo=off\n' $id $id "$LAB/wt-$id" "$P" > "$LAB/state/$id.meta"
    mkdir -p "$LAB/data/$id"; printf '# Task\n## Captain'"'"'s intent\nShip commit %s.\n\n## Firstmate spec\nrace\n' "$([ $k = 2 ] && printf '%s' "${C:0:10}" | tr a-f A-F || printf '%s' "${C:0:$((6+k*4))}")" > "$LAB/data/$id/brief.md"
  done
  for k in 1 2 3; do ( "$ROOT/bin/fm-promote.sh" r$round-$k --mode no-mistakes --yolo off > "$LAB/out-$round-$k" 2>&1; echo $? > "$LAB/rc-$round-$k" ) & done; wait
  ships=$(grep -l '^kind=ship' "$LAB"/state/r$round-*.meta | wc -l | tr -d ' ')
  claims=$(grep -l "^commits=$C" "$LAB"/state/*.meta | wc -l | tr -d ' ')
  echo "round $round: exit codes $(cat "$LAB"/rc-$round-* | tr '\n' ' ')| ships=$ships | records claiming commit=$claims"
done
grep -h "^error" "$LAB"/out-* | sort | uniq -c; rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
