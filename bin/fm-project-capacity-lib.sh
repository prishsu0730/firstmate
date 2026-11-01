#!/usr/bin/env bash
# fm-project-capacity-lib.sh - how many workers a project admits at once on this
# machine, and whether a fresh worker spawn still fits.
#
# A project can depend on a machine-local resource that only a few workers can
# use at the same time: a heavy test suite, a local editor stack, a device.
# Firstmate cannot see which part of a worker's life touches that resource, so
# the captain declares how many workers the project admits on this machine, and
# bin/fm-spawn.sh defers a fresh worker beyond that number instead of launching
# it only to spend full-context turns retrying the resource. A deferred task
# keeps its queued backlog item and is dispatched again when a place frees.
# Without a declaration nothing changes and dispatch stays uncapped
# (AGENTS.md section 7).
#
# This file is the single owner of the declaration format, of what holds a
# place, and of the admission verdict. docs/configuration.md "Project capacity"
# is the operator reference, and bin/fm-spawn.sh owns where the check runs.
#
# Declaration: config/project-capacity in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine reads the same number for the same machine's resources. One line per
# project:
#   <project-name> <capacity>
# <project-name> is the project's registered name, which is the basename of its
# clone directory, and <capacity> is a positive integer of at most six digits.
# The capacity is the last whitespace-separated field, so the name before it may
# contain spaces. Blank lines are ignored. A line is a comment when it is `#`,
# when `#` is followed by whitespace, or when it starts with `#` and its last
# field is not an integer. A project whose name begins with `#` is declared by
# writing that `#` immediately against the rest of the name and ending the line
# with the capacity, for example `#repo 2`. A name that is `#`, or that begins
# with `#` followed by a space, is the same spelling as a comment and cannot be
# declared. Any other shape, a project named twice, or an unreadable file makes
# the whole declaration unreadable, and bin/fm-spawn.sh then refuses every fresh
# ship or scout spawn from this machine's homes rather than guessing which limit
# was meant.
#
# Occupancy: a place is held by every task record, in any local Firstmate home on
# this machine (fm_local_firstmate_state_dirs in bin/fm-wake-lib.sh), that
#   - is not a secondmate, which is a persistent home rather than a worker,
#   - names the same project identity, meaning its project resolves to the same
#     shared project lock path (fm_treehouse_project_lock_path), which is keyed
#     by the project's resolved origin, so workers in any clone of that origin
#     are counted, and
#   - has not supplied positive idle proof for its current launch: its meta
#     busy_gen must match .busy-gen and its trusted busy record must be idle.
#     Unarmed workers cannot release on idle evidence alone.
#     Idle release additionally
#     requires a parked, paused, or done crew state, a live tmux/herdr endpoint
#     with successful capture, and no unread steering messages. Unknown activity and uncertain reads retain occupancy.
#     Missing copies or endpoints with recovery-grade absence proof release.
# A place frees only on a fresh admission-time check of current idle or absence
# proof, or cleanup removing the record. Stored PR and status records alone
# never release a place. Relaunches and steers to released workers
# must pass admission before resuming.
# The declaration is matched by the spawning clone's directory name, so clones
# of one origin share the cap only when they use that same directory name. A
# clone of that origin under a different directory name finds no declaration
# and is not capped, though its workers still count as holders for a
# same-origin clone that is capped.
# A record whose project directory no longer exists cannot be matched and holds
# no place. Remote homes are never walked, because their workers run on another
# machine.
#
# Race safety: bin/fm-spawn.sh evaluates admission while holding the shared
# project lock and keeps holding it until the new task record is published, so
# two concurrent spawns for one project can never both publish from the same
# count. A spawn on an uncapped project can still publish a holder for a capped
# same-origin clone, so every backend takes that lock whenever the declaration
# caps any project; Orca, which otherwise never takes it, is included.
# Admission reservations publish under that same project lock.
# PR registration also takes it when the recorded project directory exists and
# its lock path resolves; registration never changes occupancy.
#
# Requires bin/fm-wake-lib.sh (root home, local homes, project lock path),
# bin/fm-secondmate-registry-lib.sh (which the local-homes walk reads), and
# bin/fm-backend.sh (fm_meta_get) to be sourced first. No side effects on source.

# Exit status of a spawn deferred because the project is at capacity: the
# sysexits "temporary failure" code, so a caller can tell a deferral that leaves
# the task queued from an ordinary failure.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_PROJECT_CAPACITY_DEFER_EXIT=75

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
FM_PROJECT_CAPACITY_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fm_project_capacity_publish() {
  local action=$1 state=$2 id=$3 lock
  case "$action" in
    reserve)
      lock=$(fm_meta_lock_path "$state/$id.meta") || return 1
      fm_lock_acquire_wait "$lock" || return 1
      if [ "${4:-}" = busy ] && [ -n "$(fm_meta_get "$state/$id.meta" busy_gen)" ]; then
        "$FM_PROJECT_CAPACITY_SCRIPT_DIR/fm-busy-event.sh" apply "$state" "$id" unknown \
          --current-gen --source fm-recovery --event send-admitted || {
            fm_lock_release "$lock"
            return 1
          }
      fi
      fm_lock_release "$lock"
      ;;
    handoff)
      [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
        || { echo "error: task metadata is unavailable" >&2; exit 1; }
      META_DEVICE=$(fm_pr_file_device "$META") || exit 1
      STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
      [ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
      META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          pr=*|pr_head=*) ;;
          *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
        esac
      done < "$META"
      printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
      [ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
      chmod 0600 "$META_TMP" || exit 1
      fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
      fm_pr_metadata_identity_parse "$META_TMP" || exit 1
      [ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
        && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
        && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
      fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
      mv -f -- "$META_TMP" "$META" || exit 1
      META_TMP=
      fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
      fm_pr_metadata_identity_parse "$META" || exit 1
      [ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
        && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
        && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
      ;;
    *) return 1 ;;
  esac
}

# Succeeds only when fm-crew-state.sh positively reads the record as not
# executing. Any failed, timed-out, or unrecognized read returns 1, so the
# record keeps its place.
fm_project_capacity_record_released() {  # <state-dir> <task-id>
  local verdict activity endpoint backend message
  [ -r "$1/$2.meta" ] || return 1
  if [ -e "$1/$2.inbox" ]; then
    [ -d "$1/$2.inbox" ] && [ -r "$1/$2.inbox" ] && [ -x "$1/$2.inbox" ] || return 1
    for message in "$1/$2.inbox/"*.msg; do
      [ ! -e "$message" ] && [ ! -L "$message" ] || return 1
    done
  fi
  local worktree target absence
  worktree=$(fm_meta_get "$1/$2.meta" worktree)
  [ -z "$worktree" ] || [ -d "$worktree" ] || return 0
  backend=$(fm_backend_of_meta "$1/$2.meta")
  target=$(fm_backend_target_of_meta "$1/$2.meta")
  # Positional parameters expand in the child shell.
  # shellcheck disable=SC2016
  endpoint=$(fm_run_timed 15 bash -c '
    . "$1/fm-backend.sh"
    fm_backend_agent_state "$2" "$3"
  ' bash "$FM_PROJECT_CAPACITY_SCRIPT_DIR" "$backend" "$target" 2>/dev/null) || endpoint=unknown
  case "$endpoint" in
    missing|dead)
      # Positional parameters expand in the child shell.
      # shellcheck disable=SC2016
      absence=$(fm_run_timed 15 bash -c '
        . "$1/fm-backend.sh"
        . "$1/fm-control-lib.sh"
        fm_control_endpoint_absence_verdict "$2" "$3" "$4"
      ' bash "$FM_PROJECT_CAPACITY_SCRIPT_DIR" "$backend" "$target" "$1/$2.meta" 2>/dev/null) || return 1
      case "$absence" in gone$'\t'*|dead$'\t'*) return 0 ;; *) return 1 ;; esac
      ;;
  esac
  # shellcheck disable=SC2016
  activity=$(fm_run_timed 15 bash -c '
    . "$1/fm-backend.sh"
    . "$1/fm-busy-lib.sh"
    gen=$(fm_meta_get "$2/$3.meta" busy_gen)
    [ -n "$gen" ] && [ "$gen" = "$(fm_busy_current_gen "$2" "$3")" ] || exit 1
    record=$(fm_busy_record_read "$2" "$3") || exit 1
    harness=$(fm_meta_get "$2/$3.meta" harness)
    state=${record%% *}
    source=${record#* }; source=${source%% *}
    fm_busy_source_trusted "$harness" "$source" || exit 1
    printf "%s" "$state"
  ' bash "$FM_PROJECT_CAPACITY_SCRIPT_DIR" "$1" "$2") || return 1
  [ "$activity" = idle ] || return 1
  backend=$(fm_backend_of_meta "$1/$2.meta")
  case "$backend" in tmux|herdr) ;; *) return 1 ;; esac
  # shellcheck disable=SC2016 # Expand positional parameters in the child shell.
  endpoint=$(fm_run_timed 15 bash -c '
    . "$1/fm-backend.sh"
    meta="$2/$3.meta"
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    endpoint=$(fm_backend_agent_state "$backend" "$target")
    if [ "$endpoint" = alive ]; then
      fm_backend_capture "$backend" "$target" 1 >/dev/null || exit 1
    fi
    printf "%s" "$endpoint"
  ' bash "$FM_PROJECT_CAPACITY_SCRIPT_DIR" "$1" "$2" 2>/dev/null) || endpoint=unknown
  case "$endpoint" in
    missing|dead) return 1 ;;
    alive) ;;
    *) return 1 ;;
  esac
  verdict=$(FM_STATE_OVERRIDE="$1" FM_CREW_STATE_NO_FORGE=1 \
    fm_run_timed 15 "$FM_PROJECT_CAPACITY_SCRIPT_DIR/fm-crew-state.sh" "$2" 2>/dev/null) || return 1
  case "$verdict" in
    'state: unknown '*) return 1 ;;
  esac
  case "$verdict" in
    'state: parked '* | 'state: paused '* | 'state: done '*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# The config directory holding this machine's declaration: the spawning home's
# own <config-dir> when that home is the local root (so an override of it
# applies), otherwise the root home's config/.
fm_project_capacity_config_dir() {  # <spawning-home> <spawning-config-dir>
  local home=$1 config=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$config"
  else
    printf '%s/config\n' "$root"
  fi
}

# Read the declared capacity for one project.
# Sets FM_PROJECT_CAPACITY_FILE to the declaration path, FM_PROJECT_CAPACITY
# to the project's capacity, or to empty when the project declares none, and
# FM_PROJECT_CAPACITY_ANY to 1 when the declaration caps any project at all.
# Returns 1 with FM_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
fm_project_capacity_lookup() {  # <config-dir> <project-name>
  local name=$2 line lineno=0 pname pcap seen='|'
  FM_PROJECT_CAPACITY_FILE="$1/project-capacity"
  FM_PROJECT_CAPACITY=
  FM_PROJECT_CAPACITY_ANY=
  FM_PROJECT_CAPACITY_ERROR=
  if [ ! -e "$FM_PROJECT_CAPACITY_FILE" ] && [ ! -L "$FM_PROJECT_CAPACITY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_PROJECT_CAPACITY_FILE" ] || [ ! -r "$FM_PROJECT_CAPACITY_FILE" ]; then
    FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    # '#' followed by whitespace is always a comment, including one that ends
    # with a number. A line that begins with '#' glued to the rest of a name is
    # a declaration only when its last field is an integer; any other such line
    # stays a comment, so a note does not refuse every spawn.
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in
          *[!0-9]*) continue ;;
        esac
        ;;
    esac
    # The capacity is the last field, so the name before it may hold spaces.
    pcap=${line##*[[:space:]]}
    pname=${line%"$pcap"}
    pname=${pname%"${pname##*[![:space:]]}"}
    if [ -z "$pname" ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno is not '<project-name> <capacity>'"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$pcap" in
      '' | *[!0-9]* | 0*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity that is not a positive integer"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#pcap}" -gt 6 ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity longer than six digits"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$seen" in
      *"|$pname|"*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno names $pname a second time"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    seen="$seen$pname|"
    [ "$pname" != "$name" ] || FM_PROJECT_CAPACITY=$pcap
  done < "$FM_PROJECT_CAPACITY_FILE"
  [ "$seen" = '|' ] || FM_PROJECT_CAPACITY_ANY=1
  return 0
}

# Count the task records holding a place in one project's capacity.
# <project-lock> is fm_treehouse_project_lock_path for the project being
# admitted, and <project-dir> is that project's own directory, which matches
# without recomputing its identity. The local homes come from
# fm_local_firstmate_state_dirs <first-state>. <own-id> is the task being
# admitted or resumed; its own record in <first-state> is excluded so it
# cannot consume its own admission place.
# Sets FM_PROJECT_CAPACITY_OCCUPANTS to the count and
# FM_PROJECT_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders,
# each outside <first-state> qualified with its home. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
fm_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i
  local -a cache_dirs cache_locks
  FM_PROJECT_CAPACITY_OCCUPANTS=0
  FM_PROJECT_CAPACITY_OCCUPANT_IDS=
  FM_PROJECT_CAPACITY_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_PROJECT_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  cache_dirs=("$own")
  cache_locks=("$want")
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_PROJECT_CAPACITY_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_PROJECT_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      project=$(fm_meta_get "$meta" project)
      [ -n "$project" ] || continue
      lock=
      i=0
      while [ "$i" -lt "${#cache_dirs[@]}" ]; do
        if [ "${cache_dirs[$i]}" = "$project" ]; then
          lock=${cache_locks[$i]}
          break
        fi
        i=$((i + 1))
      done
      if [ "$i" -ge "${#cache_dirs[@]}" ]; then
        lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null) || lock=
        cache_dirs+=("$project")
        cache_locks+=("$lock")
      fi
      [ -n "$lock" ] && [ "$lock" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      if fm_project_capacity_record_released "$state" "$id"; then
        continue
      fi
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
      FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
    done
  done
  return 0
}
