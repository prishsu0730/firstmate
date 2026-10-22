#!/usr/bin/env bash
# fm-test-detached.sh - run Firstmate's behavior tests in a detached tmux session
# whose life does not depend on the calling agent, with a durable per-file result
# log that a later run resumes from.
#
# Usage:
#   fm-test-detached.sh [--name <run>] [--fresh] <fm-test-run.sh selection...>
#   fm-test-detached.sh --status <run>
#
# Supported selections are --all, --family <name>, --lane <lane>,
# --proven-isolated, --exclude-family <name>, or script paths. Execution options
# and --changed (which implies an execution timeout) are refused. Selection
# is resolved once into a
# saved list, then each script runs one at a time through `bin/fm-test-run.sh
# <script>`, so the runner's own semantics (markers, family isolation, placement
# refusal under FM_TASK_ID) are unchanged. The command prints where the results
# live and exits at once.
#
# Run record: <state>/test-runs/<run>/, where <state> is $FM_STATE_OVERRIDE or
# $FM_HOME/state (FM_HOME defaults to this checkout).
#   scripts.list   the resolved selection, one script per line
#   results.log    FINISHED exit=<n> at=<epoch> <script>, then one COMPLETE line
#   runner.log     START/BEGIN/END lines for the worker itself
#   out/           the full output of each script
#
# Resume: run the same command again after Claude Code or the Mac restarts. A
# script with a FINISHED line (pass or fail) is skipped; one that was cut off
# mid-run has none and runs again. The default <run> is derived from the
# selection and this checkout, so the same command finds the same record.
# --name picks the record explicitly. A record made on a different commit, or a
# changed selection, is refused; --fresh moves the old record aside to
# <run>.prev-<epoch> and starts over. A run that is still live is never touched.
#
# tmux isolation: every tmux call goes to a PRIVATE server, `tmux -L
# $FM_TEST_DETACHED_SOCKET` (default fm-test-runs), never the server the caller
# or the fleet's workers live on. The name `default` is refused. The worker gets
# the caller's environment minus TMUX and TMUX_PANE, so no test can reach back
# to a shared server through an inherited $TMUX. The private server exits by
# itself when its last session ends; nothing here ever kills a server.
#
# Exit: 0 started, already running, or already complete; 2 refusal or bad use.
set -u

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
RUNS="${FM_STATE_OVERRIDE:-$FM_HOME/state}/test-runs"
SOCK="${FM_TEST_DETACHED_SOCKET:-fm-test-runs}"

die() { printf 'fm-test-detached: %s\n' "$*" >&2; exit 2; }

case "$SOCK" in
  default) die "FM_TEST_DETACHED_SOCKET=default is the shared tmux server; pick a private name" ;;
  ''|*[!A-Za-z0-9_.-]*) die "FM_TEST_DETACHED_SOCKET '$SOCK' may only use letters, digits, '_', '.' and '-'" ;;
esac

# The only tmux entry point in this script: always the private socket.
# A newly started server must not retain the launcher's run lock.
tm() { env -u TMUX -u TMUX_PANE tmux -L "$SOCK" "$@" 9>&-; }

session_for() {
  local canonical
  canonical=$(cd "$RUNS" && pwd -P) || return 1
  printf 'fm-test-%s\n' "$(printf '%s/%s' "$canonical" "$1" | git hash-object --stdin)"
}

session_live() { tm has-session -t "=$(session_for "$1")" 2>/dev/null; }

# finished <results.log> <script>: the script already has a recorded result.
finished() {
  [ -f "$1" ] || return 1
  awk -v s="$2" '$1 == "FINISHED" && $NF == s { f = 1 } END { exit !f }' "$1"
}

count_finished() { # <results.log> -> "<finished> <failed>"
  [ -f "$1" ] || { echo "0 0"; return; }
  awk '$1 == "FINISHED" { n++; if ($2 != "exit=0") f++ } END { print n + 0, f + 0 }' "$1"
}

count_lines() { # <file> -> number of non-empty lines
  awk 'NF { n++ } END { print n + 0 }' "$1" 2>/dev/null || echo 0
}

worker() { # <run-dir>
  local dir=$1 script out rc n f
  printf 'START at=%s pid=%s\n' "$(date +%s)" "$$" >> "$dir/runner.log"
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    finished "$dir/results.log" "$script" && continue
    out="$dir/out/$(printf '%s' "$script" | tr '/' '_').log"
    printf 'BEGIN at=%s %s\n' "$(date +%s)" "$script" >> "$dir/runner.log"
    "$ROOT/bin/fm-test-run.sh" "$script" > "$out" 2>&1 < /dev/null
    rc=$?
    printf 'FINISHED exit=%s at=%s %s\n' "$rc" "$(date +%s)" "$script" >> "$dir/results.log"
    printf 'END at=%s exit=%s %s\n' "$(date +%s)" "$rc" "$script" >> "$dir/runner.log"
  done < "$dir/scripts.list"
  read -r n f < <(count_finished "$dir/results.log")
  printf 'COMPLETE total=%s failed=%s at=%s\n' "$n" "$f" "$(date +%s)" >> "$dir/results.log"
}

status() { # <run>
  local dir="$RUNS/$1" total n f state current
  [ -d "$dir" ] || die "no run named '$1' under $RUNS"
  total=$(count_lines "$dir/scripts.list")
  read -r n f < <(count_finished "$dir/results.log")
  if session_live "$1"; then state=running
  elif grep -q '^COMPLETE ' "$dir/results.log" 2>/dev/null; then state=complete
  else state=stopped; fi
  printf 'run=%s state=%s finished=%s/%s failed=%s\nresults=%s\n' "$1" "$state" "$n" "$total" "$f" "$dir"
  if [ "$state" = running ]; then
    # The last BEGIN without a later END is the script in flight.
    current=$(awk '$1 == "BEGIN" { cur = $NF } $1 == "END" { cur = "" } END { print cur }' "$dir/runner.log" 2>/dev/null)
    [ -z "$current" ] || printf 'running: %s\n' "$current"
  fi
  awk '$1 == "FINISHED" && $2 != "exit=0" { print "failed: " $NF }' "$dir/results.log" 2>/dev/null
}

name='' fresh=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    --worker) [ $# -eq 2 ] || die "--worker takes one run directory"; worker "$2"; exit 0 ;;
    --status) [ $# -eq 2 ] || die "--status takes one run name"; status "$2"; exit 0 ;;
    --name) [ $# -ge 2 ] || die "--name needs a value"; name=$2; shift 2 ;;
    --fresh) fresh=1; shift ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || die "give a selection for fm-test-run.sh (for example --all or tests/x.test.sh)"
selection_args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --all|--proven-isolated|--family=*|--lane=*|--exclude-family=*) shift ;;
    --family|--lane|--exclude-family)
      [ $# -ge 2 ] || die "$1 needs a value"
      shift 2 ;;
    --) break ;;
    -*) die "unsupported detached option: $1; use fm-test-run.sh directly" ;;
    *) shift ;;
  esac
done
set -- "${selection_args[@]}"
command -v tmux > /dev/null 2>&1 || die "tmux is required and was not found on PATH"
# The worker is launched as an argument vector, which tmux only honours from 3.0.
tmux_major=$(tmux -V 2> /dev/null | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p')
[ -z "$tmux_major" ] || [ "$tmux_major" -ge 3 ] || die "tmux 3.0 or newer is required (found major version $tmux_major)"

selection="$*"
if [ -z "$name" ]; then
  name="run-$(printf '%s %s' "$ROOT" "$selection" | cksum | cut -d' ' -f1)"
fi
case "$name" in
  ''|*[!A-Za-z0-9_-]*) die "run name '$name' may only use letters, digits, '_' and '-'" ;;
esac
head_sha=$(git -C "$ROOT" rev-parse HEAD 2> /dev/null || echo unknown)

mkdir -p "$RUNS" || die "cannot create $RUNS"
RUNS=$(cd "$RUNS" && pwd -P) || die "cannot resolve $RUNS"
dir="$RUNS/$name"
command -v python3 >/dev/null 2>&1 || die "python3 is required for run locking"
exec 9>"$RUNS/.$name.lock" || die "cannot open the run lock"
python3 -c 'import fcntl; fcntl.flock(0, fcntl.LOCK_EX)' <&9 || die "cannot lock the run"
if session_live "$name"; then
  [ "$fresh" -eq 0 ] || die "run '$name' is still live; refusing --fresh"
  printf 'already running\nresults=%s\nstatus: %s --status %s\n' "$dir" "$SELF" "$name"
  exit 0
fi

if [ -d "$dir" ] && [ "$fresh" -eq 1 ]; then
  prev="$dir.prev-$(date +%s)"
  mv "$dir" "$prev" || die "cannot move the old record aside"
  printf 'old record kept at %s\n' "$prev"
fi

if [ -d "$dir" ]; then
  [ "$(cat "$dir/head" 2> /dev/null)" = "$head_sha" ] ||
    die "run '$name' was recorded on another commit; use --fresh to start over (the old record is kept)"
  [ "$(cat "$dir/selection" 2> /dev/null)" = "$selection" ] ||
    die "run '$name' was recorded for another selection; use --fresh or a different --name"
  if grep -q '^COMPLETE ' "$dir/results.log" 2> /dev/null; then
    printf 'already complete\nresults=%s\nstatus: %s --status %s\n' "$dir" "$SELF" "$name"
    exit 0
  fi
else
  mkdir -p "$dir/out" || die "cannot create $dir"
  list=$("$ROOT/bin/fm-test-run.sh" --list "$@") || { rm -rf "$dir"; die "fm-test-run.sh could not list the selection"; }
  [ -n "$list" ] || { rm -rf "$dir"; die "the selection matched no test scripts"; }
  printf '%s\n' "$list" > "$dir/scripts.list"
  printf '%s\n' "$selection" > "$dir/selection"
  printf '%s\n' "$head_sha" > "$dir/head"
fi

# A private server that already exists keeps the environment of whoever started
# it, so hand the worker the caller's own environment explicitly (task marker,
# PATH, live-gate switches) instead of relying on inheritance. TMUX and
# TMUX_PANE are dropped so nothing the tests run can address a shared server.
worker_env=()
for var in $(compgen -e); do
  case "$var" in TMUX|TMUX_PANE) continue ;; esac
  worker_env+=("$var=${!var}")
done
tm new-session -d -s "$(session_for "$name")" -c "$ROOT" -- \
  env -i "${worker_env[@]}" bash "$SELF" --worker "$dir" || die "tmux could not start the detached session"

read -r n _ < <(count_finished "$dir/results.log")
printf 'started in tmux session %s on private socket %s (%s of %s scripts already finished)\nresults=%s\nstatus: %s --status %s\n' \
  "$(session_for "$name")" "$SOCK" "$n" "$(count_lines "$dir/scripts.list")" "$dir" "$SELF" "$name"
