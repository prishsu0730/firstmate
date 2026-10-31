#!/usr/bin/env bash
# Busy-event writer lifecycle without a running harness or backend.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT

busy() { bash "$ROOT/bin/fm-busy-event.sh" "$@"; }
record() { cat "$TMP/task.busy-state"; }

test_lifecycle() {
  local gen before
  gen=$(busy arm "$TMP" task) || fail 'arm failed'
  [ "$(cat "$TMP/task.busy-gen")" = "$gen" ] || fail 'generation sidecar'
  case "$(record)" in
    "v1 gen=$gen seq=1 state=busy source=fm-spawn event=launch-brief ts="*) ;;
    *) fail 'default seed record' ;;
  esac
  before=$(record)
  busy progress "$TMP" task --gen "$gen" || fail 'progress failed'
  [ -f "$TMP/task.progress" ] || fail 'progress marker missing'
  [ "$(record)" = "$before" ] || fail 'progress changed record'
  busy apply "$TMP" task unknown --gen "$gen" --source fm-recovery --event tool-start || fail 'unknown event failed'
  before=$(record)
  busy apply "$TMP" task idle --gen "$gen" --source fm-recovery --event tool-end --only-if-event other || fail 'conditional no-op failed'
  [ "$(record)" = "$before" ] || fail 'mismatched condition changed record'
  busy apply "$TMP" task idle --current-gen --source fm-recovery --event tool-end --only-if-event tool-start || fail 'conditional update failed'
  case "$(record)" in *' seq=3 state=idle source=fm-recovery event=tool-end '*) ;; *) fail 'conditional sequence or fields' ;; esac
  before=$(record)
  busy apply "$TMP" task busy --gen "$gen" --source fm-recovery --event retry --only-if-event tool-end || fail 'idle condition no-op failed'
  [ "$(record)" = "$before" ] || fail 'conditional update reopened idle turn'
  pass 'arm defaults, progress isolation and conditional event sequencing'
}

test_rearm_retire() {
  local old gen before command
  old=$(cat "$TMP/task.busy-gen")
  gen=$(busy arm "$TMP" task --state idle --source fm-recovery --event reset) || fail 'rearm failed'
  [ "$old" != "$gen" ] || fail 'rearm reused generation'
  [ ! -e "$TMP/task.progress" ] || fail 'rearm retained progress'
  before=$(record)
  for command in apply progress retire; do
    if [ "$command" = apply ]; then
      busy apply "$TMP" task busy --gen "$old" --source fm-recovery --event late > "$TMP/out" 2> "$TMP/err"
    else
      busy "$command" "$TMP" task --gen "$old" > "$TMP/out" 2> "$TMP/err"
    fi
    [ "$?" -eq 1 ] || fail "stale $command accepted"
    [ "$(record)" = "$before" ] || fail "stale $command changed record"
    [ ! -e "$TMP/task.progress" ] || fail 'stale progress created marker'
  done
  busy retire "$TMP" task --current-gen || fail 'retire failed'
  [ ! -e "$TMP/task.busy-gen" ] && [ ! -e "$TMP/task.busy-state" ] || fail 'retire retained files'
  busy retire "$TMP" task --gen "$gen" || fail 'repeated retire failed'
  [ ! -e "$TMP/task.busy-state.lock" ] || fail 'writer lock leaked'
  pass 'rearm rejects stale mutations and retirement is idempotent'
}

test_invalid() {
  local rc
  busy progress "$TMP" task --current-gen > "$TMP/out" 2> "$TMP/err"
  rc=$?
  [ "$rc" -eq 2 ] || fail 'progress accepted current-gen'
  busy arm "$TMP" '../escape' > "$TMP/out" 2> "$TMP/err"
  rc=$?
  [ "$rc" -eq 1 ] || fail 'unsafe task id accepted'
  busy apply "$TMP" task busy --gen missing --source fm-recovery --event retry > "$TMP/out" 2> "$TMP/err"
  rc=$?
  [ "$rc" -eq 1 ] || fail 'unarmed task accepted'
  [ ! -e "$TMP/task.busy-state" ] || fail 'refused input created record'
  pass 'invalid progress mode, unsafe ids and unarmed events are refused'
}

test_lifecycle
test_rearm_retire
test_invalid
