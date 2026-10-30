#!/usr/bin/env bash
# Automatic recovery across the adapters with no per-pane process information.
# Fake cmux, zellij, and orca executables sit on PATH, so the watcher's probe
# and the real fm-control and fm-spawn processes cross the same process
# boundary they cross in production. Each fake keeps its endpoint in a small
# state directory and records everything delivered to it.
#   1. An exit record with a live endpoint relaunches into the SAME endpoint,
#      keeps the work, carries the note, and a later exit is recovered again.
#   2. An endpoint that vanished is never rebound: the work stays and the
#      refusal is visible.
#   3. A vanished endpoint with no exit record is never relaunched.
#   4. Exit and relaunch both refuse an agent that may still be running.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

TMP_ROOT=$(fm_test_tmproot fm-worker-backend-relaunch) || exit 1
mkdir -p "$TMP_ROOT" || exit 1
TMP_ROOT=$(cd "$TMP_ROOT" && pwd) || exit 1
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT

RUN_ID=01M6WK0RKERRVN0000000000AB
GEN=s100.1
CASE_NUM=0

# Shared by every fake: remember a delivered line, and model what the live agent
# does with it. A staged launch is kept so the test can run the real file later.
write_fake_common() {  # <dir>
  cat > "$1/fake/common.sh" <<'SH'
D=$FM_FAKE_DIR
deliver() {
  local payload=$1 staged
  printf '%s\n' "$payload" >> "$D/literal"
  case "$payload" in
    ". '"*"'")
      staged=${payload#". '"}; staged=${staged%"'"}
      [ ! -f "$staged" ] || { cp "$staged" "$D/last-launch"; cat "$staged" >> "$D/literal"; }
      ;;
  esac
}
screen() {
  printf 'shell\n%s\n%s\n%s\n' "$1" "$(cat "$D/cwd")" "$2"
}
SH
}

write_fake_cmux() {  # <fakebin>
  cat > "$1/cmux" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_FAKE_DIR/common.sh"
case "${1:-} ${2:-}" in
  'workspace list') jq -cn --arg t "$(cat "$D/title")" '{workspaces:[{id:"ws-1",title:$t}]}'; exit 0 ;;
esac
case "${1:-}" in
  version) echo 'cmux 99.0.0' ;;
  ping) echo pong ;;
  list-panes)
    if [ -e "$D/gone" ]; then echo '{"panes":[]}'
    else echo '{"panes":[{"selected_surface_id":"sf-1","surface_ids":["sf-1"]}]}'; fi
    ;;
  send)
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
    deliver "${2:-}"
    ;;
  send-key) printf '%s\n' "$*" >> "$D/keys" ;;
  read-screen) jq -cn --arg t "$(screen __FM_CMUX_CWD_BEGIN__ __FM_CMUX_CWD_END__)" '{text:$t}' ;;
  *) printf 'unexpected: %s\n' "$*" >> "$D/unexpected"; exit 1 ;;
esac
SH
  chmod +x "$1/cmux"
}

write_fake_zellij() {  # <fakebin>
  cat > "$1/zellij" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_FAKE_DIR/common.sh"
if [ "${1:-}" = --version ]; then echo 'zellij 0.44.0'; exit 0; fi
if [ "${1:-}" = list-sessions ]; then echo zses; exit 0; fi
[ "${1:-}" != --session ] || shift 2
[ "${1:-}" != action ] || shift
case "${1:-}" in
  list-panes)
    if [ -e "$D/gone" ]; then echo '[]'
    else echo '[{"id":7,"tab_id":3,"is_plugin":false}]'; fi
    ;;
  list-tabs) jq -cn --arg t "$(cat "$D/title")" '[{tab_id:3,name:$t}]' ;;
  paste)
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
    deliver "${2:-}"
    ;;
  send-keys) printf '%s\n' "$*" >> "$D/keys" ;;
  dump-screen) screen __FM_ZELLIJ_CWD_BEGIN__ __FM_ZELLIJ_CWD_END__ ;;
  *) printf 'unexpected: %s\n' "$*" >> "$D/unexpected"; exit 1 ;;
esac
SH
  chmod +x "$1/zellij"
}

write_fake_orca() {  # <fakebin>
  cat > "$1/orca" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_FAKE_DIR/common.sh"
case "${1:-} ${2:-}" in
  'status --json') echo '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}' ;;
  'terminal send')
    [ ! -e "$D/gone" ] || { echo '{"ok":false,"error":{"message":"terminal not found"}}'; exit 1; }
    text=
    while [ "$#" -gt 0 ]; do
      case "$1" in --text) text=${2:-}; shift 2 ;; *) shift ;; esac
    done
    [ -z "$text" ] || deliver "$text"
    echo '{"ok":true,"result":{}}'
    ;;
  'terminal read')
    [ ! -e "$D/gone" ] || { echo '{"ok":false,"error":{"message":"terminal not found"}}'; exit 1; }
    jq -cn --arg t "$(screen '' '')" '{ok:true,result:{text:$t}}'
    ;;
  *) printf 'unexpected: %s\n' "$*" >> "$D/unexpected"; exit 1 ;;
esac
SH
  chmod +x "$1/orca"
}

write_fake_tools() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  write_fake_common "$1"
  write_fake_cmux "$fb"
  write_fake_zellij "$fb"
  write_fake_orca "$fb"
  # Recovery here must never reach a different session provider.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$FM_FAKE_DIR/unexpected"
exit 1
SH
  # The stand-in agent the staged launch file starts: it exits at once.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
branch=\$(git symbolic-ref --quiet --short HEAD)
head=\$(git rev-parse HEAD)
if [ "\${1:-} \${2:-}" = "axi status" ]; then
  printf 'run:\n  id: %s\n  branch: %s\n  status: running\n  head: %s\n' "$RUN_ID" "\$branch" "\$head"
  exit 0
elif [ "\${1:-}" = axi ]; then
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  %s,%s,running,%s,\n' "$RUN_ID" "\$branch" "\$head"
  exit 0
fi
exit 1
SH
  chmod +x "$fb/tmux" "$fb/claude" "$fb/sleep" "$fb/no-mistakes"
}

target_for() {  # <backend>
  case "$1" in
    cmux) printf 'ws-1:sf-1' ;;
    zellij) printf 'zses:7' ;;
    orca) printf 'term-1' ;;
  esac
}

case_env() {  # <case-dir> <command...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u ZELLIJ -u ZELLIJ_SESSION_NAME \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_WORKER_LIVENESS_GRACE_SECS=0 \
    "$@"
}

# new_worker <backend> sets CASE_DIR to a case holding one In-flight worker on
# <backend> with a real isolated copy, a landed commit, and uncommitted work.
new_worker() {
  local backend=$1 dir home id=wk wt proj target title
  CASE_NUM=$((CASE_NUM + 1))
  dir="$TMP_ROOT/case-$CASE_NUM"
  home="$dir/home"
  wt="$dir/wt"
  proj="$dir/proj"
  target=$(target_for "$backend")
  mkdir -p "$home/state" "$home/data/$id" "$dir/fake"
  : > "$dir/fake/literal"
  write_fake_tools "$dir"
  fm_git_worktree "$proj" "$wt" "task-$id" >/dev/null
  printf 'landed\n' > "$wt/landed.txt"
  git -C "$wt" add landed.txt
  git -C "$wt" commit -qm "unlanded work for $id"
  printf 'in progress\n' > "$wt/uncommitted.txt"
  printf '# Task\n## Captain'"'"'s intent\nKeep working.\n\n## Firstmate spec\nFinish.\n' > "$home/data/$id/brief.md"
  {
    if [ "$backend" = orca ]; then echo "window=fm-$id"; else echo "window=$target"; fi
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "backend=$backend"
    echo "spawn_gen=$GEN"
    case "$backend" in
      cmux) echo "cmux_workspace_id=ws-1"; echo "cmux_surface_id=sf-1" ;;
      zellij) echo "zellij_session=zses"; echo "zellij_tab_id=3"; echo "zellij_pane_id=7" ;;
      orca) echo "orca_worktree_id=wt-1::$wt"; echo "terminal=term-1" ;;
    esac
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  title=fm-wk
  case "$backend" in
    cmux|zellij)
      # shellcheck disable=SC2016 # Expanded by the inner shell.
      title=$(case_env "$dir" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source "$2"
        "fm_backend_$2_scoped_title" fm-wk' _ "$ROOT" "$backend")
      ;;
  esac
  printf '%s' "$title" > "$dir/fake/title"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  tasks-axi add "$id" "backend relaunch fixture" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  CASE_DIR=$dir
}

run_tick() {  # <case-dir>
  local dir=$1 rc=0
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  case_env "$dir" bash -c '. "$1/bin/fm-watch.sh"
    wake() { printf "%s\n" "$1" >> "$FM_HOME/wake-delivered"; }
    worker_liveness_tick' _ "$ROOT" > "$dir/tick.out" 2>&1 || rc=$?
  # Age the tick marker so the next tick probes again.
  [ ! -e "$dir/home/state/.worker-liveness-tick" ] || touch -t 200001010000 "$dir/home/state/.worker-liveness-tick"
  return "$rc"
}

launches() {  # <case-dir>
  grep -c 'Firstmate operational input waiting: read' "$1/fake/literal" || true
}

evidence() {  # <case-dir>
  cat "$1/tick.out" "$1/home/wake-delivered" "$1/fake/unexpected" "$1/home/state/.worker-relaunch-wk" 2>/dev/null
}

assert_work_kept() {  # <case-dir> <why>
  [ -f "$1/wt/uncommitted.txt" ] || fail "$2: uncommitted work was lost"
  git -C "$1/wt" log --format=%s | grep -Fx 'unlanded work for wk' >/dev/null || fail "$2: the unlanded commit was lost"
}

test_exit_record_relaunches_into_the_same_endpoint() {  # <backend>
  local backend=$1 dir state gen brief target
  new_worker "$backend"
  dir=$CASE_DIR
  target=$(target_for "$backend")
  printf '%s\n' 'working [at=1]: started' "paused [at=2]: waiting on run $RUN_ID" > "$dir/home/state/wk.status"
  mkdir -p "$dir/home/state/wk.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=3\n--\nPlease also check the docs.\n' > "$dir/home/state/wk.inbox/001.msg"
  printf '%s\n' "$GEN" > "$dir/home/state/.worker-exit-wk"

  # shellcheck disable=SC2016 # Expanded by the inner shell.
  state=$(case_env "$dir" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state "$2" "$3"' _ "$ROOT" "$backend" "$target")
  [ "$state" = dead ] || fail "$backend: an open endpoint with an exit record should read dead, got '$state'"

  run_tick "$dir" || fail "$backend: the tick failed: $(evidence "$dir")"
  [ "$(launches "$dir")" = 1 ] || fail "$backend: the exited worker should relaunch once: $(evidence "$dir")"
  case "$backend" in
    orca) [ "$(sed -n 's/^terminal=//p' "$dir/home/state/wk.meta")" = "$target" ] || fail "$backend: the relaunch left its recorded endpoint" ;;
    *) [ "$(sed -n 's/^window=//p' "$dir/home/state/wk.meta")" = "$target" ] || fail "$backend: the relaunch left its recorded endpoint" ;;
  esac
  [ "$(sed -n 's/^worktree=//p' "$dir/home/state/wk.meta")" = "$dir/wt" ] || fail "$backend: the relaunch left its isolated copy"
  assert_work_kept "$dir" "$backend relaunch"
  brief=$(cat "$dir/home/data/wk/brief.md")
  assert_contains "$brief" "paused [at=2]: waiting on run" "$backend: the note should carry the last status lines"
  assert_contains "$brief" "No-mistakes run: $RUN_ID (running" "$backend: the note should name the active run"
  assert_contains "$brief" "001.msg: Please also check the docs." "$backend: the note should list the unread message"
  assert_grep 'check: worker wk auto-relaunched after its agent exited' "$dir/home/wake-delivered" "$backend: the relaunch should be reported"

  # A fresh agent is not treated as dead: the old record belongs to the old run.
  run_tick "$dir" || fail "$backend: the follow-up tick failed: $(evidence "$dir")"
  [ "$(launches "$dir")" = 1 ] || fail "$backend: a running replacement was relaunched"

  # The real staged launch file, run with the stand-in agent, proves its exit.
  gen=$(sed -n 's/^spawn_gen=//p' "$dir/home/state/wk.meta")
  [ "$gen" != "$GEN" ] || fail "$backend: the relaunch kept the old incarnation"
  [ -s "$dir/fake/last-launch" ] || fail "$backend: no staged launch file was delivered: $(cat "$dir/fake/literal")"
  (cd "$dir/wt" && case_env "$dir" bash "$dir/fake/last-launch") > "$dir/launch.out" 2>&1 \
    || fail "$backend: the staged launch file failed: $(cat "$dir/launch.out")"
  [ "$(cat "$dir/home/state/.worker-exit-wk")" = "$gen" ] || fail "$backend: the launch file did not record its own exit"
  run_tick "$dir" || fail "$backend: the second recovery tick failed: $(evidence "$dir")"
  [ "$(launches "$dir")" = 2 ] || fail "$backend: a later exit should be recovered: $(evidence "$dir")"
  pass "$backend: an exit record relaunches into the same endpoint with work and note kept, and a later exit recovers again"
}

test_vanished_endpoint_is_never_rebound() {  # <backend>
  local backend=$1 dir out rc=0
  new_worker "$backend"
  dir=$CASE_DIR
  printf '%s\n' "$GEN" > "$dir/home/state/.worker-exit-wk"
  : > "$dir/fake/gone"
  out=$(case_env "$dir" "$ROOT/bin/fm-control.sh" wk relaunch --note 'Resume work' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$backend: a relaunch onto a vanished endpoint should refuse: $out"
  [ "$(launches "$dir")" = 0 ] || fail "$backend: nothing should be launched: $out"
  assert_work_kept "$dir" "$backend vanished endpoint"
  case "$backend" in
    cmux|zellij) assert_contains "$out" "cannot safely rebind a missing endpoint" "$backend: the refusal should say why" ;;
    orca) assert_contains "$out" "reads 'unreadable'" "$backend: the refusal should say why" ;;
  esac
  pass "$backend: a vanished endpoint is refused visibly and the work stays"
}

test_vanished_endpoint_without_exit_record_is_not_relaunched() {  # <backend>
  local backend=$1 dir
  new_worker "$backend"
  dir=$CASE_DIR
  : > "$dir/fake/gone"
  run_tick "$dir" || fail "$backend: the tick failed: $(evidence "$dir")"
  run_tick "$dir" || fail "$backend: the second tick failed: $(evidence "$dir")"
  [ "$(launches "$dir")" = 0 ] || fail "$backend: an unproven absence was relaunched"
  assert_work_kept "$dir" "$backend unproven absence"
  case "$backend" in
    cmux|zellij)
      [ "$(grep -c 'wk' "$dir/home/wake-delivered")" = 1 ] \
        || fail "$backend: exactly one notice expected: $(evidence "$dir")"
      ;;
    orca)
      # A failed Orca terminal read cannot tell gone from unreachable.
      [ ! -s "$dir/home/wake-delivered" ] || fail "$backend: an unreadable terminal should stay quiet: $(evidence "$dir")"
      ;;
  esac
  pass "$backend: a vanished endpoint with no exit record is not relaunched"
}

test_possibly_running_agent_is_refused() {  # <backend>
  local backend=$1 dir out rc=0
  new_worker "$backend"
  dir=$CASE_DIR
  out=$(case_env "$dir" "$ROOT/bin/fm-control.sh" wk relaunch --note 'Resume work' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$backend: relaunch must refuse a running agent: $out"
  [ "$(launches "$dir")" = 0 ] || fail "$backend: a running agent got a second launch: $out"
  assert_contains "$out" "reads 'ambiguous'" "$backend: the refusal should name the state"
  # These adapters cannot tell a running agent from a bare shell, so the exit
  # verb refuses visibly and types nothing rather than guess.
  rc=0
  out=$(case_env "$dir" "$ROOT/bin/fm-control.sh" wk exit 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$backend: the exit verb should refuse without a positive reading: $out"
  assert_contains "$out" "reads 'ambiguous'" "$backend: the exit refusal should name the state"
  [ ! -s "$dir/fake/literal" ] || fail "$backend: the exit refusal typed into the endpoint: $(cat "$dir/fake/literal")"
  # Once the agent itself has exited, the same relaunch goes through.
  printf '%s\n' "$GEN" > "$dir/home/state/.worker-exit-wk"
  out=$(case_env "$dir" "$ROOT/bin/fm-control.sh" wk relaunch --note 'Resume work' 2>&1) \
    || fail "$backend: relaunch after the agent exited failed: $out"
  [ "$(launches "$dir")" = 1 ] || fail "$backend: relaunch after the agent exited did not launch: $out"
  pass "$backend: exit and relaunch refuse a possibly running agent, and relaunch works once it has exited"
}

for backend in cmux zellij orca; do
  test_exit_record_relaunches_into_the_same_endpoint "$backend"
  test_vanished_endpoint_is_never_rebound "$backend"
  test_vanished_endpoint_without_exit_record_is_not_relaunched "$backend"
  test_possibly_running_agent_is_refused "$backend"
done

echo "# all fm-worker-backend-relaunch tests passed"
