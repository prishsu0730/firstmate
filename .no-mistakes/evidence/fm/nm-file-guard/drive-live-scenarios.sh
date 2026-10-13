#!/usr/bin/env bash
# Live scenario driver for the per-ticket file boundary (fm/nm-file-guard).
# Runs the real scripts from the run worktree against a disposable lab home.
set -u
WT=/Users/priscillahsu/.no-mistakes/worktrees/d3979e0d8bb7/01M4THY31EK41PG47D4PWTT0MC
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX"); git -C "$WT" archive d0106db82c17edf41591d67486f24b644c7618ec | tar -x -C "$BASE"
cleanup() { rm -rf "$LAB" "$BASE"; }
trap cleanup EXIT
run() { echo "\$ $*"; "$@"; echo "[exit $?]"; }
hr() { echo; echo "=================== $* ==================="; }

hr "S1 brief WITH --allowed-files"
printf '# comment\n\n./bin/fm-brief.sh\ntests/*.test.sh\ndocs/**/*.md\n  ./././src/a b.sh  \n' > "$LAB/list.txt"
echo "--- input list:"; cat "$LAB/list.txt"
run "$WT/bin/fm-brief.sh" t-allow demo --mode no-mistakes --allowed-files "$LAB/list.txt"
echo "--- recorded list data/t-allow/allowed-files:"; cat -e "$LAB/data/t-allow/allowed-files"
echo "--- Allowed files section of generated brief:"; sed -n '/^# Allowed files/,/^# /p' "$LAB/data/t-allow/brief.md" | sed '$d'
run "$WT/bin/fm-file-boundary.sh" recorded t-allow

hr "S2 brief WITHOUT list is byte-identical to the base commit"
run "$WT/bin/fm-brief.sh" t-none demo --mode no-mistakes
cp "$LAB/data/t-none/brief.md" "$LAB/new.md"; rm -rf "$LAB/data/t-none"
run "$BASE/bin/fm-brief.sh" t-none demo --mode no-mistakes
if cmp "$LAB/new.md" "$LAB/data/t-none/brief.md"; then echo "IDENTICAL: new-code brief == base-code brief"; else echo "DIFFERENT"; diff "$LAB/data/t-none/brief.md" "$LAB/new.md"; fi
echo "allowed-files record present? $( [ -e "$LAB/data/t-none/allowed-files" ] && echo yes || echo no)"
run "$WT/bin/fm-file-boundary.sh" recorded t-none
run "$WT/bin/fm-file-boundary.sh" check t-none

hr "S3 brief refusals (adversarial list input)"
n=0
for bad in '/etc/passwd' 'src/../secret' './' '# only comment'; do
  n=$((n + 1)); printf '%s\n' "$bad" > "$LAB/bad.txt"; id=t-bad$n
  echo "--- list: '$bad'"
  run "$WT/bin/fm-brief.sh" $id demo --mode no-mistakes --allowed-files "$LAB/bad.txt"
  echo "scaffold left behind? $( [ -e "$LAB/data/$id" ] && echo yes || echo no)"
done
printf 'a\n' > "$LAB/ok.txt"; run "$WT/bin/fm-brief.sh" t-sc demo --scout --allowed-files "$LAB/ok.txt"

hr "S4 worker runs the exact command printed in its brief (disposable repo)"
R=$LAB/repo; git init -q --bare "$LAB/origin.git"; git init -q -b main "$R"; git -C "$R" config user.email t@t; git -C "$R" config user.name t
mkdir -p "$R/bin" "$R/tests" "$R/docs/x"; echo a > "$R/bin/fm-brief.sh"; echo r > "$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" remote add origin "$LAB/origin.git"; git -C "$R" push -q origin main; git -C "$R" remote set-head origin main
git -C "$R" checkout -qb fm/t-allow
echo b >> "$R/bin/fm-brief.sh"; echo t > "$R/tests/new.test.sh"; echo d > "$R/docs/a.md"; echo d > "$R/docs/x/b.md"; mkdir -p "$R/src"; echo s > "$R/src/a b.sh"
git -C "$R" add -A; git -C "$R" commit -qm inlist
echo "--- branch changes:"; git -C "$R" diff --name-only main...HEAD
CMD=$(sed -n '/^# Allowed files/,/^# /p' "$LAB/data/t-allow/brief.md" | grep -o '`FM_HOME=[^`]*`' | tr -d '`')
echo "command copied from brief: $CMD"
echo "--- in-list commit:"; (cd "$R" && eval "$CMD"; echo "[exit $?]")
echo x > "$R/README.md"; mkdir -p "$R/tests/deep"; echo t > "$R/tests/deep/x.test.sh"; git -C "$R" add -A; git -C "$R" commit -qm extra
echo "--- after also touching README.md and tests/deep/x.test.sh (single * must not cross dirs):"; (cd "$R" && eval "$CMD"; echo "[exit $?]")

hr "S5 adversarial: odd names, rename, worktree= from meta, base_branch"
R2=$LAB/repo2; git clone -q "$LAB/origin.git" "$R2"; git -C "$R2" config user.email t@t; git -C "$R2" config user.name t; git -C "$R2" checkout -qb fm/t-ren
mkdir -p "$LAB/data/t-ren"; printf 'docs/new.md\ndocs/café.md\ndocs/a"b.md\n' > "$LAB/data/t-ren/allowed-files"
printf 'worktree=%s\nbase_branch=main\n' "$R2" > "$LAB/state/t-ren.meta"
mkdir -p "$R2/docs"; echo c > "$R2/docs/café.md"; echo q > "$R2/docs/a\"b.md"; git -C "$R2" add -A; git -C "$R2" commit -qm odd
echo "--- non-ASCII + double-quote names in list and commit (run from / so meta worktree= must be used):"; (cd / && run "$WT/bin/fm-file-boundary.sh" check t-ren)
git -C "$R2" mv README.md docs/new.md; git -C "$R2" commit -qm rename
echo "--- rename README.md -> docs/new.md (old path must count):"; (cd / && run "$WT/bin/fm-file-boundary.sh" check t-ren)
printf 'worktree=%s\nbase_branch=nope\n' "$R2" > "$LAB/state/t-ren.meta"
echo "--- missing origin/<base_branch> must exit 2, not pass:"; (cd / && run "$WT/bin/fm-file-boundary.sh" check t-ren)

hr "S6 PR mode against the real GitHub API (read-only, closed PR #9)"
PR=https://github.com/prishsu0730/firstmate/pull/9
mkdir -p "$LAB/data/t-pr"; printf 'bin/fm-spawn.sh\nbin/fm-duplicate-intake.sh\ntests/*.test.sh\n' > "$LAB/data/t-pr/allowed-files"
echo "--- list without AGENTS.md:"; run "$WT/bin/fm-file-boundary.sh" check t-pr --pr "$PR"
printf 'AGENTS.md\n' >> "$LAB/data/t-pr/allowed-files"
echo "--- list with AGENTS.md:"; run "$WT/bin/fm-file-boundary.sh" check t-pr --pr "$PR"
echo "--- bound to the real head:"; run "$WT/bin/fm-file-boundary.sh" check t-pr --pr "$PR" --head e9b5ab02d1f4271a7237af1be4d942897d2115c0
echo "--- bound to a wrong head:"; run "$WT/bin/fm-file-boundary.sh" check t-pr --pr "$PR" --head 0000000000000000000000000000000000000000
echo "--- task with no list:"; run "$WT/bin/fm-file-boundary.sh" check t-none --pr "$PR"

cleanup; trap - EXIT
echo; echo "lab removed: $( [ -e "$LAB" ] && echo no || echo yes)"
