#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/git-config-helpers.sh"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP_ROOT=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP_ROOT"' EXIT
home=$TMP_ROOT/home
mkdir -p "$home"/{state,data,config,projects/repo}
git -C "$home/projects/repo" init -q -b main
fakebin=$TMP_ROOT/fakebin
mkdir "$fakebin"
cat > "$fakebin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$*" in
  *pane_current_command*) printf 'codex\n' ;;
  *capture-pane*) printf 'working\n' ;;
  *) printf '%%1\n' ;;
esac
TMUX
chmod +x "$fakebin/tmux"
cat > "$home/data/backlog.md" <<'BACKLOG'
## In flight

## Queued
- [ ] held - Held (repo: repo) (kind: ship) (hold: Choose) (hold-kind: captain)
- [ ] program - Program (repo: repo) (kind: program)
- [ ] mate - Mate (repo: repo) (kind: secondmate)
- [ ] blocked - Blocked blocked-by: absent (repo: repo) (kind: ship)
- [ ] future - Future (repo: repo) (kind: scout) (hold-until: 2999-01-01)
- [ ] ready - Ready (repo: repo) (kind: ship)
- [ ] scout - Scout (repo: repo) (kind: scout)

## Done
BACKLOG
for id in worker parked; do
  printf '%s\n' \
    "project=$home/projects/repo" "worktree=$home/projects/missing-$id" \
    'kind=ship' 'harness=codex' "window=firstmate:$id" > "$home/state/$id.meta"
done
printf 'parked: waiting\n' > "$home/state/parked.status"
snapshot() {
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json
}
for declaration in $'repo\t3' 'repo   3'; do
  printf '%s\n' "$declaration" > "$home/config/project-capacity"
  out=$(snapshot) || fail 'capacity snapshot'
  jq -e '.free_slots == [{project:"repo",free:1,ready_task_ids:["ready","scout"]}]' <<< "$out" >/dev/null \
    || fail "canonical capacity and eligible queue: $out"
done
printf 'repo 2\n' > "$home/config/project-capacity"
out=$(snapshot) || fail 'full snapshot'
jq -e '.free_slots == []' <<< "$out" >/dev/null || fail 'full capacity advertised as free'
printf 'repo 0\n' > "$home/config/project-capacity"
if snapshot > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'invalid capacity advertised as free'
fi
pass 'snapshot shares occupancy and declaration rules and excludes held non-worker tickets'
