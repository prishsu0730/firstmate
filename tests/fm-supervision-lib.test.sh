#!/usr/bin/env bash
# Local supervision predicates and registered work detection.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"
TMP=$(mktemp -d)
trap 'rmdir "$TMP"/* "$TMP" 2>/dev/null || true' EXIT

# Each group removes its own fixtures, leaving only empty directories for the trap.
test_empty() {
  mkdir "$TMP/empty"
  fm_supervision_status "$TMP/empty"
  [ "$FM_SUP_IN_FLIGHT:$FM_SUP_SOURCES:$FM_SUP_CHECKS" = 0:0:0 ] || fail 'empty counts'
  [ "$FM_SUP_NEEDED:$FM_SUP_WATCHER_FRESH:$FM_SUP_QUEUE_PENDING:$FM_SUP_BEACON_DESC" = false:false:false:never ] || fail 'empty status'
  if fm_supervision_needed "$TMP/empty"; then fail 'empty home needs watcher'; fi
  if fm_supervision_unhealthy "$TMP/empty"; then fail 'empty home unhealthy'; fi
  fm_supervision_status "$TMP/absent"
  [ "$FM_SUP_NEEDED" = false ] || fail 'missing directory needs watcher'
  pass 'empty and absent directories need no supervision'
}

test_registered_work() {
  local dir="$TMP/work"
  mkdir "$dir" "$dir/procevent"
  touch "$dir/task.meta" "$dir/procevent/wait.source" "$dir/custom.check.sh"
  fm_supervision_status "$dir"
  [ "$FM_SUP_IN_FLIGHT:$FM_SUP_SOURCES:$FM_SUP_CHECKS" = 1:1:0 ] || fail 'untrusted check counted'
  fm_supervision_unhealthy "$dir" || fail 'work without beacon healthy'
  touch "$dir/custom.check-trust"
  fm_supervision_status "$dir"
  [ "$FM_SUP_CHECKS" = 1 ] || fail 'registered check missing'
  unlink "$dir/task.meta"
  unlink "$dir/procevent/wait.source"
  fm_supervision_needed "$dir" || fail 'registered check needs no watcher'
  unlink "$dir/custom.check-trust"
  if fm_supervision_needed "$dir"; then fail 'unregistered check needs watcher'; fi
  touch "$dir/x-watch.check.sh" "$dir/x-watch.check-trust"
  fm_supervision_status "$dir"
  [ "$FM_SUP_NEEDED:$FM_SUP_CHECKS" = true:0 ] || fail 'relay counting'
  unlink "$dir/x-watch.check.sh"
  unlink "$dir/x-watch.check-trust"
  unlink "$dir/custom.check.sh"
  rmdir "$dir/procevent"
  pass 'tasks, sources, trusted checks, and relay require supervision'
}

test_beacon_queue() {
  local dir="$TMP/beacon"
  mkdir "$dir"
  touch "$dir/task.meta" "$dir/.last-watcher-beat" "$dir/.wake-queue"
  fm_supervision_status "$dir" 3600
  [ "$FM_SUP_WATCHER_FRESH:$FM_SUP_QUEUE_PENDING" = true:false ] || fail 'fresh beacon or empty queue'
  if fm_supervision_unhealthy "$dir" 3600; then fail 'fresh watcher unhealthy'; fi
  printf 'pending\n' > "$dir/.wake-queue"
  touch -t 200001010000 "$dir/.last-watcher-beat"
  fm_supervision_status "$dir" 1
  [ "$FM_SUP_WATCHER_FRESH:$FM_SUP_QUEUE_PENDING" = false:true ] || fail 'old beacon or unread queue'
  case "$FM_SUP_BEACON_DESC" in *'s ago') ;; *) fail 'beacon age description' ;; esac
  fm_supervision_unhealthy "$dir" 1 || fail 'stale watcher healthy'
  unlink "$dir/task.meta"
  fm_supervision_status "$dir"
  [ "$FM_SUP_NEEDED:$FM_SUP_QUEUE_PENDING" = false:true ] || fail 'queue alone requires supervision'
  unlink "$dir/.last-watcher-beat"
  unlink "$dir/.wake-queue"
  pass 'beacon age and unread queue are independent of work counts'
}

test_empty
test_registered_work
test_beacon_queue
