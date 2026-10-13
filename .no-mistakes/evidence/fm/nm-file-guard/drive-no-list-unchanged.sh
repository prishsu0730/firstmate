#!/usr/bin/env bash
# Prove a brief made without --allowed-files is unchanged from the base commit,
# for every ship mode. The base copy lives in a different directory, so its
# install path is replaced with the worktree path before comparing.
set -u
WT=/Users/priscillahsu/.no-mistakes/worktrees/d3979e0d8bb7/01M4THY31EK41PG47D4PWTT0MC
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX"); git -C "$WT" archive d0106db82c17edf41591d67486f24b644c7618ec | tar -x -C "$BASE"
BR=$(cd "$BASE" && pwd -P)
for mode in no-mistakes direct-PR local-only; do
  "$WT/bin/fm-brief.sh" "t-$mode" demo --mode "$mode" >/dev/null
  mv "$LAB/data/t-$mode/brief.md" "$LAB/new-$mode.md"
  rec=$(ls "$LAB/data/t-$mode" | grep -c allowed-files)
  rm -rf "$LAB/data/t-$mode"
  "$BASE/bin/fm-brief.sh" "t-$mode" demo --mode "$mode" >/dev/null
  BN=$(basename "$BASE")
  sed "s#[^' \`]*/$BN#$WT#g" "$LAB/data/t-$mode/brief.md" > "$LAB/old-$mode.md"
  if cmp -s "$LAB/old-$mode.md" "$LAB/new-$mode.md"; then
    echo "mode=$mode: IDENTICAL to base-commit brief ($(wc -c < "$LAB/new-$mode.md" | tr -d ' ') bytes); allowed-files records written: $rec"
  else
    echo "mode=$mode: DIFFERENT"; diff "$LAB/old-$mode.md" "$LAB/new-$mode.md"
  fi
done
rm -rf "$LAB" "$BASE"
echo "lab removed: $( [ -e "$LAB" ] && echo no || echo yes)"
