#!/usr/bin/env bash
# Build a disposable lab home + git project + private tmux server for G4b live checks.
set -eu
WT=/Users/priscillahsu/.no-mistakes/worktrees/d3979e0d8bb7/01M4T5F4EWZSZJBYY5C4BVQ4NH
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/user-home" "$LAB/treehouse" "$LAB/out"
echo claude > "$LAB/config/crew-harness"
echo tmux > "$LAB/config/backend"
touch "$LAB/state/.last-watcher-beat"
G=(-c user.name=Lab -c user.email=lab@example.invalid)
# origin + project clone
git init -q --bare -b main "$LAB/origin.git"
git init -q -b main "$LAB/projects/demo"
P="$LAB/projects/demo"
echo hello > "$P/README.md"
git -C "$P" add README.md
git -C "$P" "${G[@]}" commit -qm "base"
git -C "$P" remote add origin "$LAB/origin.git"
git -C "$P" push -q -u origin main
git -C "$P" remote set-head origin main
# floating commits: exist as objects, held by no branch
tree=$(git -C "$P" rev-parse 'main^{tree}')
X=$(git -C "$P" "${G[@]}" commit-tree "$tree" -p main -m "floating X")
Y=$(git -C "$P" "${G[@]}" commit-tree "$tree" -p main -m "floating Y")
BASE=$(git -C "$P" rev-parse main)
printf 'LAB=%s\nX=%s\nY=%s\nBASE=%s\n' "$LAB" "$X" "$Y" "$BASE" > /tmp/fm-g4b-lab.env
cat /tmp/fm-g4b-lab.env
# private tmux server running a plain shell as the primary pane
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab -f /dev/null new-session -d -s primary -x 200 -y 50 -c "$WT" \
  -e FM_HOME="$LAB" -e HOME="$LAB/user-home" -e CLAUDE_CONFIG_DIR= -e TREEHOUSE_ROOT="$LAB/treehouse" \
  -e DISABLE_AUTOUPDATER=1 bash --noprofile --norc
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab ls
