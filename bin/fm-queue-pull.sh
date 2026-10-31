#!/usr/bin/env bash
# Timer-driven away queue intake, independent of worker status events.
# Usage: fm-queue-pull.sh tick
#        fm-queue-pull.sh prepare <task-id> <project-dir> <spawn-options>...
# prepare saves an explicit firstmate-resolved spawn argv (JSON) beside the
# task brief at data/<id>/dispatch.json. It neither infers a delivery/profile
# choice nor starts work. Use it when deferring a fully briefed task.
# tick runs under the watcher once a minute while a valid away record exists.
# tasks-axi ready owns blocker/hold/date eligibility. Each prepared eligible
# task is passed directly to fm-spawn.sh, without a shell or bypassed guards.
# At most one successful launch per tick; failures are retried next minute.
# Queued items without a plan wake supervision once per changed queue report
# for normal intake. state/.queue-pull-report records every non-start reason.
# With no start, landing, or running job for 1800 seconds, one durable check
# names that report. The episode resets only on observed progress, survives
# watcher restarts, and never repeats just because its wake was acknowledged.
# No quiet/attended dispatch. State paths follow the ordinary FM_* overrides.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent "$SCRIPT_DIR/.."
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

queue_ids() {
  # IDs are the first TOON column, never titles or arbitrary shell text.
  awk '/^  [a-zA-Z0-9][a-zA-Z0-9_-]*,/ {sub(/^  /, ""); sub(/,.*/, ""); print}'
}

queue_prepare() {
  local id=${1:-} project=${2:-} tmp arg
  case "$id" in ''|*[!a-zA-Z0-9_-]*) echo 'error: invalid task id' >&2; return 2 ;; esac
  [ "$#" -ge 3 ] && [ -d "$project" ] && [ -f "$DATA/$id/brief.md" ] || {
    echo 'error: prepare needs an existing project, task brief, and explicit spawn options' >&2; return 2;
  }
  project=$(cd "$project" && pwd -P) || return 1
  shift 2
  for arg in "$@"; do
    case "$arg" in --relaunch|--secondmate|--batch|--allow-duplicate|--supersedes)
      echo 'error: queue plans support fresh ordinary work only' >&2; return 2 ;;
    esac
  done
  tmp=$(mktemp "$DATA/$id/.dispatch.XXXXXX") || return 1
  if ! jq -n --args '$ARGS.positional' -- "$id" "$project" "$@" > "$tmp"; then
    return 1
  fi
  chmod 600 "$tmp"
  # Atomic replacement in the already inspected task directory.
  mv "$tmp" "$DATA/$id/dispatch.json"
}

queue_tick() {
  local now last entered report queued ready ids eligible id plan arg out rc
  local running=0 started=0 needs_intake=0 meta task kind progress fingerprint old event
  local -a argv
  fm_afk_contract_away_present "$STATE" || return 0
  fm_afk_contract_validate "$STATE/.afk-contract" >/dev/null 2>&1 || return 0
  fm_lock_try_acquire "$STATE/.queue-pull.lock" || return 0
  trap 'fm_lock_release "$STATE/.queue-pull.lock"' EXIT
  now=$(date +%s)
  last=$(cat "$STATE/.queue-pull-last" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge 60 ] || return 0
  printf '%s\n' "$now" > "$STATE/.queue-pull-last"
  report=$(mktemp "$STATE/.queue-pull-report.XXXXXX") || return 1
  QUEUE_PULL_REPORT=$report
  trap 'unlink "$QUEUE_PULL_REPORT" 2>/dev/null || true; fm_lock_release "$STATE/.queue-pull.lock"' EXIT
  if queued=$(fm_run_timed 15 "$SCRIPT_DIR/fm-tasks-axi.sh" list --state queued 2>&1) \
     && ready=$(fm_run_timed 15 "$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>&1) \
     && printf '%s\n' "$queued" | grep -Eq '^tasks\[|^count: 0$' \
     && printf '%s\n' "$ready" | grep -Eq '^ready\[|^ready: 0 unblocked queued tasks$'; then
    ids=$(printf '%s\n' "$queued" | queue_ids)
    # Restrict parsing to ready[], excluding the ready_public_followups group.
    eligible=$(printf '%s\n' "$ready" | awk '/^ready\[/ {on=1; next} /^[^ ]/ {on=0} on {print}' | queue_ids)
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if ! printf '%s\n' "$eligible" | grep -Fx "$id" >/dev/null; then
        printf '%s: blocked, held, date-gated, or otherwise not dispatchable (tasks-axi ready)\n' "$id" >> "$report"
        continue
      fi
      if [ -e "$STATE/$id.meta" ]; then
        printf '%s: existing task metadata; reconcile before dispatch\n' "$id" >> "$report"
        continue
      fi
      plan="$DATA/$id/dispatch.json"
      if [ ! -f "$plan" ] || [ -L "$plan" ]; then
        printf '%s: needs firstmate intake and explicit spawn plan\n' "$id" >> "$report"
        needs_intake=1
        continue
      fi
      if ! jq -e --arg id "$id" 'type == "array" and length >= 3 and .[0] == $id and all(.[]; type == "string" and (contains("\u0000") | not) and (contains("\n") | not))' "$plan" >/dev/null 2>&1; then
        printf '%s: invalid dispatch plan\n' "$id" >> "$report"
        continue
      fi
      if [ "$started" -eq 1 ]; then
        printf '%s: next timer tick after this launch\n' "$id" >> "$report"
        continue
      fi
      argv=()
      while IFS= read -r arg; do argv+=("$arg"); done < <(jq -r '.[]' "$plan")
      rc=0
      for arg in "${argv[@]}"; do
        case "$arg" in --relaunch|--secondmate|--batch|--allow-duplicate|--supersedes) rc=1 ;; esac
      done
      if [ "$rc" -ne 0 ]; then
        printf '%s: plan is not a fresh ordinary dispatch\n' "$id" >> "$report"
        continue
      fi
      # Never execute a command from a plan; fm-spawn owns every launch gate.
      if out=$("$SCRIPT_DIR/fm-spawn.sh" "${argv[@]}" 2>&1); then
        started=1
        printf '%s: started through fm-spawn\n' "$id" >> "$report"
      else
        rc=$?
        printf '%s: spawn refused (exit %s): %s\n' "$id" "$rc" "$out" >> "$report"
      fi
    done <<< "$ids"
    [ -n "$ids" ] || printf 'no queued work\n' >> "$report"
  else
    printf 'backlog unavailable: %s\n' "${queued:-} ${ready:-}" >> "$report"
  fi

  # Only reconciled working state proves running work; uncertainty is reported.
  entered=$(fm_afk_contract_read_field "$STATE/.afk-contract" entered_epoch 2>/dev/null || true)
  case "$entered" in ''|*[!0-9]*) entered=$now ;; esac
  progress=$(cat "$STATE/.queue-pull-progress" 2>/dev/null || printf '%s' "$entered")
  case "$progress" in ''|*[!0-9]*) progress=$now ;; esac
  [ "$progress" -ge "$entered" ] || progress=$entered
  # Lifecycle owners record even jobs that started and landed between ticks.
  if [ -f "$STATE/.queue-pull-activity" ]; then
    while IFS=$'\t' read -r last event; do
      case "$last" in ''|*[!0-9]*) continue ;; esac
      case "$event" in start|landing) ;; *) continue ;; esac
      [ "$last" -le "$progress" ] || progress=$last
    done < "$STATE/.queue-pull-activity"
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    [ "$kind" != secondmate ] || continue
    task=${meta##*/}; task=${task%.meta}
    out=$(FM_CREW_STATE_NO_FORGE=1 "$SCRIPT_DIR/fm-crew-state.sh" "$task" 2>/dev/null || true)
    case "$out" in
      'state: working '*) running=1 ;;
      'state: unknown '*|'state: conflict '*) printf '%s: current worker activity uncertain: %s\n' "$task" "$out" >> "$report" ;;
    esac
  done
  if [ "$started" -eq 1 ] || [ "$running" -eq 1 ]; then progress=$now; fi
  printf '%s\n' "$progress" > "$STATE/.queue-pull-progress"
  fingerprint=$(cksum < "$report")
  old=$(cat "$STATE/.queue-pull-intake" 2>/dev/null || true)
  # Publish reasons before any wake can ask supervision to read them.
  mv "$report" "$STATE/.queue-pull-report"
  if [ "$needs_intake" -eq 1 ] && [ "$fingerprint" != "$old" ]; then
    fm_wake_append check queue-intake "check: queue intake needed; read $STATE/.queue-pull-report, complete normal intake and dispatch through bin/fm-spawn.sh (save deferred argv with bin/fm-queue-pull.sh prepare)" || return 1
    printf '%s\n' "$fingerprint" > "$STATE/.queue-pull-intake"
  fi
  old=$(cat "$STATE/.queue-pull-alarm" 2>/dev/null || true)
  if [ $((now - progress)) -ge 1800 ] && [ "$old" != "$progress" ]; then
    fm_wake_append check queue-idle "check: no start, landing, or running job for 30 minutes; reason: $STATE/.queue-pull-report" || return 1
    printf '%s\n' "$progress" > "$STATE/.queue-pull-alarm"
  fi
}

case "${1:-}" in
  prepare) shift; queue_prepare "$@" ;;
  tick) queue_tick ;;
  *) echo 'usage: fm-queue-pull.sh tick | prepare <task-id> <project-dir> <spawn-options>...' >&2; exit 2 ;;
esac
