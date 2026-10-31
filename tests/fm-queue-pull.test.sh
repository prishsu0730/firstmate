#!/usr/bin/env bash
# Away queue timer through real tasks-axi eligibility and durable wake output.
# Spawn is the external provisioning boundary: its fixture records argv and
# creates task metadata without spending model tokens or touching a backend.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
# shellcheck source=tests/wake-helpers.sh
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue-pull)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME"/{state,data,config} "$TMP_ROOT/code/bin" "$TMP_ROOT/project with spaces"
CODE="$TMP_ROOT/code/bin"
for file in "$ROOT"/bin/*; do
  [ -f "$file" ] || continue
  ln -s "$file" "$CODE/${file##*/}"
done
# Replace only fixture symlinks, never production files.
unlink "$CODE/fm-queue-pull.sh"
cp "$ROOT/bin/fm-queue-pull.sh" "$CODE/fm-queue-pull.sh"
unlink "$CODE/fm-spawn.sh"
cat > "$CODE/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FM_HOME/spawn.log"
[ ! -f "$FM_HOME/refuse" ] || { echo 'project capacity reached'; exit 75; }
printf 'kind=ship\n' > "$FM_HOME/state/$1.meta"
exec "$FM_TEST_ROOT/bin/fm-tasks-axi.sh" start "$1"
SH
chmod +x "$CODE/fm-spawn.sh"
export FM_TEST_ROOT="$ROOT"
printf 'kind=ship\n' > "$FM_HOME/state/parked.meta"
FM_HOME="$FM_HOME" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null || fail 'away entry'

axi() { "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
tick() { "$CODE/fm-queue-pull.sh" tick || fail 'queue tick failed'; }
due() { printf '0\n' > "$FM_HOME/state/.queue-pull-last"; }
add() {
  axi add "$1" 'queue test' >/dev/null || fail 'task add'
  mkdir -p "$FM_HOME/data/$1"
  printf '# ready brief\n' > "$FM_HOME/data/$1/brief.md"
  "$CODE/fm-queue-pull.sh" prepare "$1" "$TMP_ROOT/project with spaces" --mode no-mistakes --yolo off || fail 'prepare'
}

add task.a
tick
assert_contains "$(cat "$FM_HOME/spawn.log")" "$TMP_ROOT/project with spaces" 'argv lost project whitespace'
assert_contains "$(axi show task.a)" 'state: in_flight' 'clear queued job did not start beside parked worker'
assert_contains "$(cat "$FM_HOME/state/.queue-pull-report")" 'task.a: started through fm-spawn' 'launch not recorded'
tick
[ "$(wc -l < "$FM_HOME/spawn.log" | tr -d ' ')" = 6 ] || fail 'timer repeated a start'
pass 'timer starts clear prepared work beside a parked worker exactly once'

add dependency
add blocked
axi block blocked --by dependency >/dev/null || fail 'block'
# The dependency must not itself start in this case.
axi hold dependency --reason 'test hold' --kind captain >/dev/null || fail 'hold'
due; tick
[ ! -f "$FM_HOME/state/blocked.meta" ] || fail 'blocked task started'
assert_contains "$(cat "$FM_HOME/state/.queue-pull-report")" 'blocked: blocked, held, date-gated' 'blocked reason missing'
pass 'blocked and held work starts nothing and records why'

add future
axi hold future --reason 'future test' --kind captain --until 2099-01-01 >/dev/null || fail 'date hold'
due; tick
[ ! -f "$FM_HOME/state/future.meta" ] || fail 'future task started'
assert_contains "$(cat "$FM_HOME/state/.queue-pull-report")" 'future: blocked, held, date-gated' 'date reason missing'
pass 'tasks-axi date gate prevents a premature start'

axi add unprepared 'needs intake' >/dev/null || fail 'unprepared add'
due; tick
assert_contains "$(cat "$FM_HOME/state/.wake-queue")" 'queue intake needed' 'missing intake wake'
rows=$(wc -l < "$FM_HOME/state/.wake-queue")
due; tick
[ "$(wc -l < "$FM_HOME/state/.wake-queue")" = "$rows" ] || fail 'unchanged intake repeated'
pass 'unprepared work wakes ordinary intake once per changed report'

mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP_ROOT/fakebin/tmux"
PATH="$TMP_ROOT/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watcher.out" 2> "$TMP_ROOT/watcher.err" &
watch_pid=$!
wait_for_exit "$watch_pid" 200 || fail "watcher did not surface queue intake: $(cat "$TMP_ROOT/watcher.err")"
assert_contains "$(cat "$TMP_ROOT/watcher.out")" 'check: queue intake needed' 'timer result did not wake supervision'
pass 'real watcher surfaces timer intake without any worker event'

add retry
touch "$FM_HOME/refuse"
due; tick
[ ! -f "$FM_HOME/state/retry.meta" ] || fail 'refused spawn started'
assert_contains "$(cat "$FM_HOME/state/.queue-pull-report")" 'spawn refused (exit 75): project capacity reached' 'spawn refusal lost'
unlink "$FM_HOME/refuse"
due; tick
[ -f "$FM_HOME/state/retry.meta" ] || fail 'eligible work not retried'
pass 'capacity refusal is recorded and retried on the next timer tick'

add returned.a
unlink "$CODE/fm-tasks-axi.sh"
cat > "$CODE/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = ready ]; then
  "$FM_TEST_ROOT/bin/fm-afk-contract.sh" archive >/dev/null || exit 1
fi
exec "$FM_TEST_ROOT/bin/fm-tasks-axi.sh" "$@"
SH
chmod +x "$CODE/fm-tasks-axi.sh"
due; tick
[ ! -f "$FM_HOME/state/returned.a.meta" ] || fail 'dispatch continued after captain return during backlog read'
pass 'captain return during backlog read stops prepared dispatch'
unlink "$CODE/fm-tasks-axi.sh"
ln -s "$ROOT/bin/fm-tasks-axi.sh" "$CODE/fm-tasks-axi.sh"
"$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null || fail 'away reentry'

axi add quiet 'quiet task' >/dev/null || fail 'quiet add'
"$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail 'archive'
due; tick
[ ! -f "$FM_HOME/state/quiet.meta" ] || fail 'attended timer dispatched'
pass 'attended sessions do not autonomously dispatch'
