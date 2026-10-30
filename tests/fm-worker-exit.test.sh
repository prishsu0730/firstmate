#!/usr/bin/env bash
set -eu
ROOT=$PWD
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-exit.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/fakebin"
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
export PATH="$TMP_ROOT/fakebin:$PATH"
STATE=$FM_STATE_OVERRIDE
. "$ROOT/bin/fm-worker-liveness-lib.sh"
shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
for backend in $FM_BACKEND_KNOWN; do
  fm_control_backend_state_verified "$backend" || fail "known backend excluded: $backend"
  fm_backend_source "$backend" || fail "adapter unavailable: $backend"
done
fm_backend_cmux_cli() {
  [ "${EXIT_TEST_MODE:-present}" != unreadable ] || return 1
  if [ "${EXIT_TEST_MODE:-present}" = missing ]; then printf '{"panes":[]}'
  else printf '{"panes":[{"surface_ids":["surface"]}]}' ; fi
}
fm_backend_zellij_cli() {
  [ "${EXIT_TEST_MODE:-present}" != unreadable ] || return 1
  if [ "${EXIT_TEST_MODE:-present}" = missing ]; then printf '[]'
  else printf '[{"id":1,"is_plugin":false}]'; fi
}
orca() {
  [ "${EXIT_TEST_MODE:-present}" != unreadable ] || return 1
  printf '{"ok":true,"result":{"text":"shell"}}'
}
for backend in cmux zellij orca; do
  target=workspace:surface
  [ "$backend" != zellij ] || target=session:1
  [ "$backend" != orca ] || target=terminal
  meta="$FM_STATE_OVERRIDE/worker.meta"
  printf 'kind=ship\nbackend=%s\nwindow=%s\nspawn_gen=s123.1\n' "$backend" "$target" > "$meta"
  [ "$(fm_backend_agent_state "$backend" "$target")" = ambiguous ] || fail "$backend legacy worker must be ambiguous"
  printf 'false\n%s\n' "$(fm_backend_worker_exit_line "$FM_STATE_OVERRIDE" worker s123.1)" > "$TMP_ROOT/launch.sh"
  bash "$TMP_ROOT/launch.sh"
  [ "$(fm_backend_agent_state "$backend" "$target")" = dead ] || fail "$backend exit proof not consumed"
  fm_worker_liveness_probe "$meta" worker
  [ "$FM_WK_LIVE_STATUS" = relaunchable ] || fail "$backend probe excluded"
  printf 's122.1\n' > "$FM_STATE_OVERRIDE/.worker-exit-worker"
  [ "$(fm_backend_agent_state "$backend" "$target")" = ambiguous ] || fail "$backend stale proof accepted"
  printf 'kind=secondmate\nbackend=%s\nwindow=%s\nspawn_gen=s123.1\n' "$backend" "$target" > "$meta"
  [ "$(fm_backend_agent_state "$backend" "$target")" = unverified ] || fail "$backend secondmate changed"
  if fm_control_secondmate_state_verified "$backend"; then fail "$backend secondmate gate widened"; fi
  printf 'kind=scout\nbackend=%s\nwindow=%s\nspawn_gen=s123.1\n' "$backend" "$target" > "$meta"
  printf 's123.1\n' > "$FM_STATE_OVERRIDE/.worker-exit-worker"
  [ "$(EXIT_TEST_MODE=unreadable fm_backend_agent_state "$backend" "$target")" = unreadable ] || fail "$backend failed inventory accepted"
  if [ "$backend" != orca ]; then
    [ "$(EXIT_TEST_MODE=missing fm_backend_agent_state "$backend" "$target")" = missing ] || fail "$backend missing inventory ignored"
    [ "$(fm_control_endpoint_absence_verdict "$backend" "$target" "$meta")" = $'gone\t' ] || fail "$backend proof not used for absence"
  fi
  printf 'old\n' > "$FM_STATE_OVERRIDE/.worker-exit-worker"
done
mkdir -p "$TMP_ROOT/adapters/backends"
printf 'fm_backend_future_endpoint_state() { printf present; }\n' > "$TMP_ROOT/adapters/backends/future.sh"
FM_BACKEND_KNOWN="$FM_BACKEND_KNOWN future"
FM_BACKEND_LIB_DIR="$TMP_ROOT/adapters"
printf 'kind=ship\nbackend=future\nwindow=future-target\nspawn_gen=s123.1\n' > "$meta"
printf 's123.1\n' > "$FM_STATE_OVERRIDE/.worker-exit-worker"
fm_control_backend_state_verified future || fail 'future backend excluded'
[ "$(fm_backend_agent_state future future-target)" = dead ] || fail 'future classifier unavailable'
fm_worker_liveness_probe "$meta" worker
[ "$FM_WK_LIVE_STATUS" = relaunchable ] || fail 'future backend probe excluded'
pass 'exit records classify current workers across generic and future backends'
