#!/usr/bin/env bash
# Live drive of the per-ticket file boundary against a disposable lab home.
set -u
WT=$1; LAB=$2; BASE_SHA=$3
cd "$WT"
B="env -u NO_MISTAKES_GATE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME=$LAB"
run() { echo "\$ $*"; eval "$@"; echo "-> exit=$?"; echo; }
hr() { echo "================ $* ================"; }

hr "S1 bounded brief writes Allowed files section and record"
printf 'bin/a.sh\n# comment\n\n./docs/**/*.md\n' > "$LAB/list.txt"
run "$B bin/fm-brief.sh t1 demo --mode no-mistakes --allowed-files $LAB/list.txt"
cat "$LAB/list.txt" | sed 's/^/  list.txt| /'
echo "--- data/t1/allowed-files:"; cat "$LAB/data/t1/allowed-files"
echo "--- Allowed files section of data/t1/brief.md:"
awk '/^# Allowed files/{p=1} p&&/^# /&&!/^# Allowed files/{exit} p' "$LAB/data/t1/brief.md"

hr "S2 brief without a list is byte-identical to the base commit's scaffold"
OLD=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-old.XXXXXX")" && pwd -P)
git archive "$BASE_SHA" | tar -x -C "$OLD"
for side in old new; do
  L2=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$L2" >/dev/null
  root=$WT; [ $side = old ] && root=$OLD
  env -u NO_MISTAKES_GATE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME=$L2 "$root/bin/fm-brief.sh" t2 demo --mode no-mistakes >/dev/null
  sed -e "s#$L2#<LAB>#g" -e "s#$root#<ROOT>#g" "$L2/data/t2/brief.md" > "$LAB/brief-$side.md"
  ls "$L2/data/t2" | sed "s/^/  $side data\/t2: /"
  trash "$L2"
done
if cmp -s "$LAB/brief-old.md" "$LAB/brief-new.md"; then echo "IDENTICAL ($(wc -l < "$LAB/brief-new.md") lines)"; else echo "DIFFERENT"; diff "$LAB/brief-old.md" "$LAB/brief-new.md"; fi
trash "$OLD"

hr "S3 bad lists are refused before any scaffold is written"
printf '/etc/passwd\n' > "$LAB/abs.txt"; printf 'src/../secret\n' > "$LAB/dots.txt"
printf '# only comments\n\n' > "$LAB/empty.txt"; printf './\n././\n' > "$LAB/dotslash.txt"
for f in abs dots empty dotslash; do run "$B bin/fm-brief.sh bad-$f demo --mode no-mistakes --allowed-files $LAB/$f.txt; echo brief-exit=\$?; ls $LAB/data/bad-$f 2>&1 | head -1"; done
run "$B bin/fm-brief.sh sc1 demo --scout --allowed-files $LAB/list.txt"

hr "S4 local check: build a real repo + origin, run the exact command the brief prints"
git init -q --bare "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$LAB/wt" 2>/dev/null
( cd "$LAB/wt" && git checkout -q -b main && mkdir -p bin docs/x && echo base > README && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && git push -q origin main && git remote set-head origin main && git checkout -q -b fm/t1 )
printf 'worktree=%s\nbase_branch=main\n' "$LAB/wt" > "$LAB/state/t1.meta"
CMD=$(grep -o '`FM_HOME=[^`]*`' "$LAB/data/t1/brief.md" | tr -d '`')
echo "command from brief: $CMD"
( cd "$LAB/wt" && echo x > bin/a.sh && echo y > docs/top.md && echo z > docs/x/deep.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm inlist )
echo "branch changes: $(git -C "$LAB/wt" diff --name-only origin/main...HEAD | tr '\n' ' ')"
run "env -u NO_MISTAKES_GATE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE $CMD"
( cd "$LAB/wt" && echo bad > bin/b.sh && echo bad > notes.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm extra )
echo "branch changes: $(git -C "$LAB/wt" diff --name-only origin/main...HEAD | tr '\n' ' ')"
run "env -u NO_MISTAKES_GATE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE $CMD"
echo "uncommitted out-of-list file only (not committed) after reset:"
( cd "$LAB/wt" && git reset -q --hard HEAD~1 && echo w > stray.txt )
run "$B bin/fm-file-boundary.sh check t1"

hr "S5 task with no list: exit 0 with a note"
run "$B bin/fm-brief.sh t3 demo --mode no-mistakes >/dev/null; $B bin/fm-file-boundary.sh check t3"
run "$B bin/fm-file-boundary.sh recorded t3"
echo "task with no list that QUOTES the marker in its task text:"
printf '\nQuoted from an old brief:\nFile boundary: required\n' >> "$LAB/data/t3/brief.md"
run "$B bin/fm-file-boundary.sh check t3"

hr "S6 a recorded list that is lost refuses (exit 2)"
cp "$LAB/data/t1/allowed-files" "$LAB/allowed.bak"; mv "$LAB/data/t1/allowed-files" "$LAB/allowed.gone"
run "$B bin/fm-file-boundary.sh check t1"
run "$B bin/fm-file-boundary.sh recorded t1"
cp "$LAB/allowed.bak" "$LAB/data/t1/allowed-files"
run "$B bin/fm-file-boundary.sh recorded t1"

hr "S7 live GitHub PR file list (read-only) - prishsu0730/firstmate#11"
PR=https://github.com/prishsu0730/firstmate/pull/11
LIVE=$(gh pr view "$PR" --json headRefOid -q .headRefOid); echo "live head: $LIVE"
mkdir -p "$LAB/data/p1" "$LAB/data/p2"
printf 'bin/fm-*.sh\ndocs/scripts.md\ntests/**/*.test.sh\n' > "$LAB/data/p1/allowed-files"
printf 'bin/fm-brief.sh\nbin/fm-file-boundary.sh\ntests/*.sh\n' > "$LAB/data/p2/allowed-files"
echo "p1 list: $(tr '\n' ' ' < "$LAB/data/p1/allowed-files")"; run "$B bin/fm-file-boundary.sh check p1 --pr $PR"
echo "p2 list: $(tr '\n' ' ' < "$LAB/data/p2/allowed-files")"; run "$B bin/fm-file-boundary.sh check p2 --pr $PR"
run "$B bin/fm-file-boundary.sh check p1 --pr $PR --head $LIVE"
run "$B bin/fm-file-boundary.sh check p1 --pr $PR --head 0000000000000000000000000000000000000000"
run "$B bin/fm-file-boundary.sh check t3 --pr $PR"
