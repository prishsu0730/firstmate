#!/usr/bin/env bash
# Drives the real bin/fm-captain-hold.sh `complete` against a throwaway FM home
# with an armed PR poll, then checks PR poll validity with the real fm-pr-lib
# consumer. Usage: drive-captain-complete.sh <repo-root> <fresh|repair> <tmpdir>
set -u
ROOT=$1 SCEN=$2 T=$3
. "$ROOT/bin/fm-pr-lib.sh"
home=$T/home-$SCEN; mkdir -p "$home"/data "$home"/state "$home"/config "$home"/projects "$home"/fakebin
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"
done
TA=$(command -v tasks-axi)
cap() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TA" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
id=demo-origin pr=https://github.com/sample/sample/pull/54 meta=$home/state/demo-origin.meta
(cd "$home" && tasks-axi add "$id" "Ship demo" --kind ship --repo sample --start >/dev/null)
printf '%s\n' "window=firstmate:fm-$id" "worktree=$home/projects/x" "project=$home/projects/sample" \
  harness=codex kind=ship mode=ship spawn_gen=fx > "$meta"
poll_ok() { fm_pr_poll_artifacts_valid "$home/state" "$id" "$ROOT/bin/fm-pr-poll.sh" && echo "PR poll: VALID" || echo "PR poll: INVALID"; }
arm() {
  printf 'pr=%s\npr_head=%s\n' "$pr" 1111111111111111111111111111111111111111 >> "$meta"
  fm_pr_poll_prepare "$home/state" "$id" github "$pr" github.com sample/sample 54 "$ROOT/bin/fm-pr-poll.sh" \
    && fm_pr_poll_publish_prepared
}
if [ "$SCEN" = fresh ]; then
  arm
  cap hold call-a --title "Pick route" --reason "captain must pick" --repo sample --origin "$id" >/dev/null
  echo "--- before complete"; poll_ok
  echo "\$ fm-captain-hold.sh complete $id call-a"; cap complete "$id" call-a; echo "exit=$?"
else
  cap hold call-a --title "First" --reason "first pending" --repo sample --origin "$id" >/dev/null
  cap hold call-b --title "Second" --reason "second pending" --repo sample --origin "$id" >/dev/null
  arm
  printf 'decisions_reviewed=1\ndecision_keys=call-a\n' >> "$meta"
  echo "--- before complete (meta already broken by the old bug)"; cat "$meta"; poll_ok
  echo "\$ fm-captain-hold.sh complete $id call-b"; cap complete "$id" call-b; echo "exit=$?"
fi
echo "--- meta after complete"; cat "$meta"; poll_ok
echo "last decision_keys line (what meta_value reads): $(grep '^decision_keys=' "$meta" | tail -1)"
