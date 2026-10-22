#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owning session's anchor pid, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh: the harness (agent)
# process found by walking the shell's ancestry, which lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. For a Claude session that proves a
# trusted session id the anchor is CLAUDE_PID, the model-loop process, so a
# shared transient daemon or a front-end that outlives the session never keeps
# a dead session's lock alive. Line 1 keeps its whole-line pid format because
# every other reader takes the first line as the pid.
#
# The trusted id itself is recorded beside the lock in state/.lock-session, a
# sidecar written only here and only under the claim lock: refreshed on every
# confirmed-own acquisition, including the early already-mine exit that waits
# for the claim lock, removed when the acquiring session proves no trusted id,
# and left byte-identical when it already names that id. A same-session
# confirmation never rewrites line 1 while the recorded pid is alive, because
# bin/fm-startup-network.sh compares that pid across its deferred sweeps; a dead
# recorded pid is reclaimed and rewritten to this session's anchor.
#
# A live harness holder that is not the process Firstmate launched for a
# secondmate home is a FOREIGN holder - for example the Codex desktop app's
# shared app-server daemon, which inherits the home as its cwd and records itself
# in the lock, then shadows the real session Firstmate launched into the home's
# endpoint. The launched process is identified from the parent's durable launch
# record, never from the holder's name or cwd: .fm-secondmate-home names the
# mate, .fm-secondmate-parent names the parent home, the parent's
# state/<id>.meta names the tmux window Firstmate launched it into, and the
# holder is the home's own session only when its parent chain reaches one of that
# window's pane pids. A foreign holder is still refused - nothing is reclaimed
# and no process is ever signalled - but the refusal names its pid and command
# with one next step for the captain, and the parent home gets one keyed
# `blocked` line on this mate's status channel (published by this script, not
# left to the model; bin/fm-parent-channel-lib.sh owns the channel). Any step of
# that record that cannot be resolved - a primary home, a remote route, a
# herdr or zellij endpoint, an unreachable tmux - is no evidence, so the generic
# live-holder refusal applies exactly as before.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, anchor pid) is owned by the shared session-lock lib so the Claude
# Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# The parent channel resolver also owns the secondmate identity and parent
# binding reads the foreign-holder check below needs. A main home has no
# identity marker and never loads it, so its lock path is exactly what it was.
if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
  # shellcheck source=bin/fm-parent-channel-lib.sh
  [ ! -f "$SCRIPT_DIR/fm-parent-channel-lib.sh" ] || . "$SCRIPT_DIR/fm-parent-channel-lib.sh"
fi

# Pane pids of the tmux window Firstmate launched this secondmate home into, one
# per line, or non-zero when the launch record cannot be fully resolved. The
# whole chain is local and tmux-only; every gap is "unknown", never "foreign".
home_endpoint_pids() {
  local id parent_home meta window backend home_real meta_home pids
  command -v fm_parent_channel_home_id >/dev/null 2>&1 || return 1
  id=$(fm_parent_channel_home_id "$FM_HOME") || return 1
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  parent_home=$FM_SECONDMATE_PARENT_HOME
  meta="$parent_home/state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  backend=$(sed -n 's/^backend=//p' "$meta" | tail -n 1)
  case "$backend" in ''|tmux) ;; *) return 1 ;; esac
  [ "$(sed -n 's/^kind=//p' "$meta" | tail -n 1)" = secondmate ] || return 1
  meta_home=$(sed -n 's/^home=//p' "$meta" | tail -n 1)
  home_real=$(cd -P "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  [ -n "$meta_home" ] && [ "$(cd -P "$meta_home" 2>/dev/null && pwd -P)" = "$home_real" ] || return 1
  window=$(sed -n 's/^window=//p' "$meta" | tail -n 1)
  [ -n "$window" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  pids=$(tmux list-panes -t "$window" -F '#{pane_pid}' 2>/dev/null) || return 1
  [ -n "$pids" ] || return 1
  printf '%s\n' "$pids"
}

if [ "${1:-}" = "status" ]; then
  fm_session_lock_inspect "$STATE"
  if [ "$FM_LOCK_INSPECT_STATE" = held ]; then
    fm_session_lock_inspect "$STATE" "$(home_endpoint_pids 2>/dev/null || true)"
  fi
  case "$FM_LOCK_INSPECT_STATE" in
    free) echo "lock: free" ;;
    unreadable) echo "lock: unreadable" ;;
    held)
      if [ "$FM_LOCK_INSPECT_HOME_LAUNCHED" = false ]; then
        echo "lock: held by FOREIGN harness pid $FM_LOCK_INSPECT_PID ($(fm_session_lock_holder_command "$FM_LOCK_INSPECT_PID")), not the session launched for this home"
      else
        echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID"
      fi
      ;;
    *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
  esac
  exit 0
fi

me=$(fm_session_lock_anchor_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
restore_uncommitted_lock_session() {
  case "$LOCK_SESSION_PHASE" in
    1)
      case "$LOCK_SESSION_KIND" in
        1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
        2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
      esac
      ;;
    2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
  esac
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
}
commit_lock_session() {
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
  rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
}
on_lock_exit() {
  restore_uncommitted_lock_session
  [ -n "$LOCK_LINE_PRE" ] && rm -f "$LOCK_LINE_PRE"
  release_claim_lock
}
trap on_lock_exit EXIT
trap 'exit 1' HUP INT TERM

remember_lock_session() {
  [ "$LOCK_SESSION_PHASE" -eq 0 ] || return 0
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
    cp -P "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || return 1
    LOCK_SESSION_KIND=1
  else
    LOCK_SESSION_KIND=2
  fi
  LOCK_SESSION_PHASE=1
}

# Record the trusted session id beside the lock, or remove a sidecar that no
# trusted id backs. Called only while the claim lock is held. A sidecar already
# naming this id is left untouched, so a same-session confirmation keeps it
# byte-identical.
publish_lock_session() {
  local trusted recorded tmp
  if trusted=$(fm_session_lock_trusted_session_id); then
    if recorded=$(fm_session_lock_recorded_session_id "$STATE") && [ "$recorded" = "$trusted" ]; then
      return 0
    fi
    remember_lock_session || return 1
    tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || return 1
    if ! { printf '%s\n' "$trusted" > "$tmp" && mv -f "$tmp" "$LOCK_SESSION"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      return 1
    fi
    return 0
  fi
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    remember_lock_session || return 1
    rm -f "$LOCK_SESSION" 2>/dev/null || return 1
  fi
  return 0
}

publish_lock_session_or_die() {
  publish_lock_session && return 0
  echo "error: cannot record the session identity beside the lock; operate read-only until resolved" >&2
  exit 1
}

# This session already holds the lock, recorded as pid $1. Line 1 stays exactly
# as recorded while that pid is alive; only the sidecar is refreshed, under the
# claim lock, so a /clear re-key inside the same process replaces the old id.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal is a takeover rule and does not
# apply here.
confirm_own_lock() {  # <recorded-pid>
  local recorded waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$recorded" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    publish_lock_session_or_die
    commit_lock_session
    release_claim_lock
    echo "lock acquired: harness pid $recorded"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

# The live holder $1 is not the process Firstmate launched for this home: refuse
# loudly with its pid, command, and one next step, and tell the parent once.
# Returns when the holder is not provably foreign, so the caller's generic
# live-owner refusal runs unchanged. Never reclaims the lock, never signals $1.
refuse_foreign_holder() {  # <recorded-pid>
  local pid=$1 endpoints cmd note rc=0 launched_rc=0
  endpoints=$(home_endpoint_pids 2>/dev/null) || return 0
  fm_session_lock_holder_launched "$pid" "$endpoints" "$STATE" || launched_rc=$?
  [ "$launched_rc" -eq 1 ] || return 0
  cmd=$(fm_session_lock_holder_command "$pid")
  echo "error: the session lock is held by a foreign process, not the session Firstmate launched for this home (pid $pid, command: ${cmd:-unknown}); operate read-only. Next step: confirm that process is not this home's session, stop it yourself (kill $pid), then rerun bin/fm-session-start.sh - Firstmate never stops it for you." >&2
  note=$(fm_parent_channel_clean_note "foreign process holds this home's session lock (pid $pid, command: ${cmd:-unknown}); the session launched for this home stayed read-only. Confirm it is not this home's session and stop it, then restart the home's session.")
  fm_parent_channel_report "$FM_HOME" "$STATE" "blocked [key=lock-foreign-holder-$pid]: $note" || rc=$?
  case "$rc" in
    0|1) ;;
    *) echo "warning: could not publish the foreign-holder alarm to the parent channel (rc $rc)" >&2 ;;
  esac
  exit 1
}

refuse_live_owner() {  # <recorded-pid>
  local recorded
  refuse_foreign_holder "$1"
  if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $1, session $recorded); operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fi
  exit 1
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if fm_harness_pid_alive "$old"; then
    refuse_live_owner "$old"
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
    if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
      refuse_live_owner "$old"
    fi
  fi
fi
# The sidecar goes first: a fresh pid beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar and leaves the lock
# ancestry-only. After line 1 verifies as this session's anchor, a later
# signal leaves the published pair in place.
publish_lock_session_or_die
if [ -f "$LOCK" ]; then
  LOCK_LINE_PRE=$(mktemp "$STATE/.lock.pre.XXXXXX") || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! cp "$LOCK" "$LOCK_LINE_PRE" 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
fi
LOCK_SESSION_PHASE=2
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  lock_unchanged=0
  if [ -n "$LOCK_LINE_PRE" ] && cmp -s "$LOCK_LINE_PRE" "$LOCK"; then
    lock_unchanged=1
  elif [ -z "$LOCK_LINE_PRE" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    lock_unchanged=1
  fi
  if [ "$lock_unchanged" -eq 1 ]; then
    if [ "$LOCK_SESSION_KIND" -ne 0 ]; then
      LOCK_SESSION_PHASE=1
    else
      LOCK_SESSION_PHASE=0
    fi
  fi
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
commit_lock_session
release_claim_lock
echo "lock acquired: harness pid $me"
