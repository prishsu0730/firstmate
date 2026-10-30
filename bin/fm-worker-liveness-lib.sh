#!/usr/bin/env bash
# shellcheck disable=SC2034 # Probe/relaunch output globals are read by sourcing callers.
# fm-worker-liveness-lib.sh - automatic recovery of an ordinary ship or scout
# worker whose agent has exited. bin/fm-watch.sh's worker_liveness_tick drives
# this library on its own bounded cadence; the secondmate counterpart is
# bin/fm-secondmate-liveness-lib.sh, which this deliberately mirrors.
#
# Recovery goes through the one safe replace-the-agent path,
# `bin/fm-control.sh <id> relaunch --if-stopped --note-file <note>`, so the
# replacement keeps the same isolated copy and every unlanded change, and its
# instructions gain a progress note built here from the durable records: the
# last status lines, the task's no-mistakes run, and any unread steering
# messages. --if-stopped makes fm-control re-read the agent under the task's
# own control lock and refuse if it is running, so a worker someone relaunched
# by hand between this probe and that call is never exited.
#
# Only a positively stopped agent is relaunchable: the backend's recovery-grade
# `dead` verdict, or a `missing` endpoint that the control plane's absence
# proof (fm_control_endpoint_absence_verdict) establishes as gone or dead.
# Every other reading leaves the worker untouched.
#
# A worker is never relaunched when:
#   - its kind is not ship or scout, or it is remotely placed;
#   - fm-control exit stopped it deliberately (state/.worker-stopped-<id>);
#   - a backlog close is pending for it (state/<id>.backlog-close);
#   - its last status line is `done` or `failed` (finished either way), or
#     `captain-held`; `working`, `paused`, `blocked`, and `needs-decision` do
#     not prevent recovery, because a dead agent cannot receive the answer or
#     finish the wait it declared;
#   - its backlog item is closed, archived, held, or not In flight.
#
# The attempt ledger (state/.worker-relaunch-<id>, one tab-separated epoch and
# word per line) is the durable relaunch record and the input to the watcher's
# relaunch bound. An `attempt` row is written only when fm-control is actually
# invoked; a refusal because another lifecycle action holds the task, or because
# the agent was found running, appends a `released` row that hands the attempt
# back. Teardown removes the ledger, the park marker
# (state/.worker-relaunch-bound-<id>), and the stop marker.

set -u

FM_WK_LIVE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-backend.sh
. "$FM_WK_LIVE_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$FM_WK_LIVE_LIB_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$FM_WK_LIVE_LIB_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_WK_LIVE_LIB_DIR/fm-timeout-lib.sh"
if ! command -v status_line_verb >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$FM_WK_LIVE_LIB_DIR/fm-classify-lib.sh"
fi

# The backlog libraries are loaded only when a relaunch is about to happen, so
# a tick that finds every worker alive never pays for them.
fm_wk_live_require_backlog() {
  command -v fm_backlog_row_probe >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$FM_WK_LIVE_LIB_DIR/fm-tasks-axi-lib.sh" || return 1
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$FM_WK_LIVE_LIB_DIR/fm-backlog-transition-lib.sh"
}

fm_wk_live_data_dir() {
  printf '%s' "${FM_DATA_OVERRIDE:-$FM_HOME/data}"
}

fm_wk_live_first_line() {
  printf '%s\n' "$1" | sed -n '/[^[:space:]]/{s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# Last non-empty line of <id>'s status log; empty when there is none.
fm_wk_live_last_status() {  # <id>
  local f="$STATE/$1.status"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  awk 'NF { last = $0 } END { if (last != "") print last }' "$f" 2>/dev/null
}

fm_worker_liveness_ledger_add() {  # <id> <attempt|released|relaunched|failed|rearmed>
  printf '%s\t%s\n' "$(date +%s)" "$2" >> "$STATE/.worker-relaunch-$1" 2>/dev/null
}

# Attempt rows no older than <window-secs>, less the `released` rows in the
# same window. An absent ledger counts zero; an unreadable one fails.
fm_worker_liveness_recent_attempts() {  # <id> <window-secs>
  local id=$1 window=$2 ledger cutoff
  ledger="$STATE/.worker-relaunch-$id"
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  [ -f "$ledger" ] && [ -r "$ledger" ] || return 1
  cutoff=$(( $(date +%s) - window ))
  awk -F '\t' -v cutoff="$cutoff" '
    $1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "attempt" { n++ }
    $1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "released" { n-- }
    $2 == "rearmed" { n = 0 }
    END { if (n < 0) n = 0; print n + 0 }' "$ledger" 2>/dev/null
}

# fm_worker_liveness_probe <meta> <id>
#
# Read-only probe of one ordinary worker. Populates:
#
#   FM_WK_LIVE_STATUS  silent | alive | relaunchable | skipped
#   FM_WK_LIVE_STATE   the raw agent-state word
#   FM_WK_LIVE_CAUSE   relaunch cause phrase, on relaunchable
#   FM_WK_LIVE_REASON  why the worker was left alone, on skipped
#   FM_WK_LIVE_IDENT   the record's spawn_gen and control_relaunch_tx, so a
#                      relaunch can refuse when the record moved underneath it
#
# `silent` is every case that is not this library's to recover and needs no
# log line: another kind, a remote placement, an unsupported backend, no
# endpoint, a deliberate stop, a pending close, or a finished or held worker.
# `skipped` is an inconclusive agent reading, worth one triage line.
fm_worker_liveness_probe() {  # <meta> <id>
  local meta=$1 id=$2 kind backend target last verb state absence
  FM_WK_LIVE_STATUS=silent FM_WK_LIVE_STATE=unknown
  FM_WK_LIVE_CAUSE='' FM_WK_LIVE_REASON='' FM_WK_LIVE_IDENT=''
  kind=$(fm_meta_get "$meta" kind 2>/dev/null || true)
  case "$kind" in ship|scout) ;; *) return 0 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host 2>/dev/null || true)" ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  fm_control_backend_state_verified "$backend" || return 0
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  if [ -e "$STATE/.worker-stopped-$id" ] || [ -L "$STATE/.worker-stopped-$id" ]; then
    return 0
  fi
  if [ -e "$STATE/$id.backlog-close" ] || [ -L "$STATE/$id.backlog-close" ]; then
    return 0
  fi
  last=$(fm_wk_live_last_status "$id")
  if [ -n "$last" ]; then
    verb=$(status_line_verb "$last")
    case "$verb" in done|failed) return 0 ;; esac
    ! status_is_captain_held "$last" || return 0
  fi
  FM_WK_LIVE_IDENT="$(fm_meta_get "$meta" spawn_gen) $(fm_meta_get "$meta" control_relaunch_tx)"
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
  FM_WK_LIVE_STATE=$state
  case "$state" in
    alive) FM_WK_LIVE_STATUS=alive ;;
    dead)
      FM_WK_LIVE_STATUS=relaunchable
      FM_WK_LIVE_CAUSE="its agent exited and the endpoint holds no agent (backend=$backend)"
      ;;
    missing)
      absence=$(fm_control_endpoint_absence_verdict "$backend" "$target" "$meta")
      case "${absence%%$'\t'*}" in
        gone|dead)
          FM_WK_LIVE_STATUS=relaunchable
          FM_WK_LIVE_CAUSE="its recorded endpoint is proven ${absence%%$'\t'*} (backend=$backend)"
          ;;
        alive) FM_WK_LIVE_STATUS=alive ;;
        *)
          FM_WK_LIVE_STATUS=missing-unproven
          FM_WK_LIVE_REASON="endpoint reads missing, but ${absence#*$'\t'}"
          ;;
      esac
      ;;
    ambiguous) ;;
    *)
      FM_WK_LIVE_STATUS=skipped
      FM_WK_LIVE_REASON="agent state reads '$state' (backend=$backend), not a proven stop"
      ;;
  esac
  return 0
}

fm_wk_live_nm_run() {  # <branch> <worktree>
  local branch=$1 wt=$2 out run status choice timeout_secs=${FM_WORKER_LIVENESS_NM_TIMEOUT:-10}
  [ -n "$branch" ] && [ -d "$wt" ] && command -v no-mistakes >/dev/null 2>&1 || return 0
  out=$(fm_nm_run_checked "$wt" "$timeout_secs" axi) || return 0
  choice=$(fm_nm_select_run "$branch" "$out" "$wt" "$timeout_secs")
  case "$choice" in selected\|*) ;; *) return 0 ;; esac
  IFS='|' read -r _ run _ <<< "$choice"
  out=$(fm_nm_run_checked "$wt" "$timeout_secs" axi status --run "$run") || return 0
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")" = "$run" ] || return 0
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" = "$branch" ] || return 0
  fm_nm_head_matches_worktree "$wt" "$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")" \
    || fm_nm_run_is_pipeline_owned_active "$out" \
    || fm_nm_run_is_executing "$out" || return 0
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  printf '%s (%s, read from no-mistakes axi status)' "$run" "${status:-unknown status}"
}

# Write the relaunch note for <id> to <file>.
fm_worker_liveness_note() {  # <meta> <id> <file>
  local meta=$1 id=$2 file=$3 wt branch run msg body any=0
  wt=$(fm_meta_get "$meta" worktree)
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  run=$(fm_wk_live_nm_run "$branch" "$wt")
  {
    echo "The firstmate watcher relaunched you automatically: $FM_WK_LIVE_CAUSE."
    echo "Nobody stopped this task on purpose, so pick up where the last status line leaves off."
    echo
    echo "Last status lines:"
    if [ -s "$STATE/$id.status" ]; then
      awk 'NF' "$STATE/$id.status" | tail -n 10 | sed 's/^/  /'
    else
      echo "  (none recorded)"
    fi
    echo
    if [ -n "$run" ]; then
      echo "No-mistakes run: $run."
      echo "Continue that run rather than starting a second one while it is still active."
    else
      echo "No-mistakes run: unknown."
      printf 'Check no-mistakes axi and select only a run for branch %q before reading its status by --run ID.\n' "$branch"
    fi
    echo
    echo "Unread instruction messages:"
    for msg in "$STATE/$id.inbox"/*.msg; do
      [ -f "$msg" ] || continue
      body=$(awk 'seen { print } /^--$/ { seen = 1 }' "$msg" 2>/dev/null)
      printf '  %s: %s\n' "${msg##*/}" "$(fm_wk_live_first_line "$body" | cut -c1-200)"
      any=1
    done
    [ "$any" -eq 1 ] || echo "  (none)"
  } > "$file"
}

# fm_worker_liveness_relaunch <meta> <id> <timeout-secs>
#
# Acts on a `relaunchable` probe verdict. Confirms the backlog item is still
# open and In flight, re-reads the record and agent state, builds the note, and
# runs the guarded relaunch. Sets:
#
#   FM_WK_LIVE_STATUS  relaunched | failed | skipped | closed
#   FM_WK_LIVE_REASON  the skip reason, or the first line of a failure
#
# `closed` is a finished task the probe could not see from the status log
# alone; it needs no log line. Returns 0 only on relaunched.
fm_worker_liveness_relaunch() {  # <meta> <id> <timeout-secs>
  local meta=$1 id=$2 timeout=$3 data row ident state note out rc=0
  FM_WK_LIVE_REASON=''
  data=$(fm_wk_live_data_dir)
  if ! fm_wk_live_require_backlog; then
    FM_WK_LIVE_STATUS=skipped FM_WK_LIVE_REASON="backlog libraries could not be loaded"
    return 1
  fi
  if fm_backlog_row_probe "$data" "$id"; then
    row=$FM_BACKLOG_ROW_STATE
    case "$row" in
      "in_flight no no") ;;
      done\ *) FM_WK_LIVE_STATUS=closed; return 1 ;;
      *) FM_WK_LIVE_STATUS=skipped FM_WK_LIVE_REASON="backlog item reads '$row', not open and In flight"; return 1 ;;
    esac
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    FM_WK_LIVE_STATUS=closed
    return 1
  else
    FM_WK_LIVE_STATUS=skipped FM_WK_LIVE_REASON="backlog item could not be read: ${FM_BACKLOG_ROW_ERROR:-unknown error}"
    return 1
  fi
  ident="$(fm_meta_get "$meta" spawn_gen) $(fm_meta_get "$meta" control_relaunch_tx)"
  if [ "$ident" != "$FM_WK_LIVE_IDENT" ]; then
    FM_WK_LIVE_STATUS=skipped FM_WK_LIVE_REASON="task record changed since the probe"
    return 1
  fi
  note=$(mktemp "$STATE/.worker-relaunch-note-$id.XXXXXX") || {
    FM_WK_LIVE_STATUS=skipped FM_WK_LIVE_REASON="relaunch note could not be created"
    return 1
  }
  if ! fm_worker_liveness_note "$meta" "$id" "$note"; then
    rm -f "$note"
    FM_WK_LIVE_STATUS=skipped FM_WK_LIVE_REASON="relaunch note could not be written"
    return 1
  fi
  if ! fm_worker_liveness_ledger_add "$id" attempt; then
    rm -f "$note"
    FM_WK_LIVE_STATUS=skipped FM_WK_LIVE_REASON="relaunch ledger $STATE/.worker-relaunch-$id is unwritable"
    return 1
  fi
  out=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$data FM_SPAWN_NO_GUARD=1 \
    fm_run_timed "$timeout" "$FM_WK_LIVE_LIB_DIR/fm-control.sh" "$id" relaunch --if-stopped --note-file "$note" 2>&1) || rc=$?
  rm -f "$note"
  if [ "$rc" -eq 0 ]; then
    fm_worker_liveness_ledger_add "$id" relaunched || true
    FM_WK_LIVE_STATUS=relaunched
    return 0
  fi
  case "$rc:$out" in
    6:"error: lifecycle control (fm-control) refused - task '$id' is leased to the "*" supervision actor (state/.lease-$id), which is handling that task right now;"*|*"--if-stopped preserves deliberate stops"*|*"another lifecycle action is already running for task $id"*|*"--if-stopped relaunches only an agent that has already stopped"*)
      fm_worker_liveness_ledger_add "$id" released || true
      FM_WK_LIVE_STATUS=skipped
      FM_WK_LIVE_REASON=$(fm_wk_live_first_line "$out")
      return 1
      ;;
  esac
  fm_worker_liveness_ledger_add "$id" failed || true
  FM_WK_LIVE_STATUS=failed
  case "$rc" in
    124|137) FM_WK_LIVE_REASON="relaunch did not finish within ${timeout}s" ;;
    *) FM_WK_LIVE_REASON=$(fm_wk_live_first_line "$out") ;;
  esac
  [ -n "$FM_WK_LIVE_REASON" ] || FM_WK_LIVE_REASON="relaunch exited $rc with no output"
  return 1
}
