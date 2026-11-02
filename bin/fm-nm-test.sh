#!/usr/bin/env bash
# fm-nm-test.sh - the deterministic Test command the no-mistakes gate runs for
# this repository (`commands.test` in .no-mistakes.yaml).
#
# The gate's Test agent runs inside a Codex sandbox that denies ps, private
# tmux sockets, and evidence writes, so the real tests cannot run there. The
# gate runs this command itself, on the daemon host, as the Test step baseline.
#
# Usage:
#   fm-nm-test.sh [--base <git-ref>]
#   fm-nm-test.sh --list [--base <git-ref>]
#   fm-nm-test.sh --help
#
#   --base <ref>  compare against this ref. Without it the first ref that
#                 exists among origin/main and main is used; when neither
#                 exists a warning is printed and only working-tree changes
#                 are considered. An explicit ref that does not exist is
#                 refused with exit 2.
#   --list        print the selected test scripts, one per line, and exit 0
#                 without running anything.
#
# Selection prefers a changed test itself, then a backend's
# tests/fm-backend-<name>.test.sh, then tests/<basename>.test.sh.
# Otherwise, references to the filename in tests/*.test.sh select up to eight
# consumers, stable-sorted. Committed, uncommitted, and untracked changes count.
# Unmatched files (including references exceeding the cap) are named and add
# tests/fm-nm-test-contract.test.sh and tests/fm-test-run.test.sh as fallback.
# An empty diff uses the same fallback. No test family or suite walk runs.
#
# Each selected script runs separately through bin/fm-test-run.sh, which owns
# bash invocation, fixture Git isolation, and the per-script time bound, with
# inherited FM_* variables removed from its environment. The remaining scripts
# still run after a failure. The command exits non-zero when any script fails,
# and the gate parks the Test step.
# Before executing tests, probe ps and (when installed) a fresh private tmux
# server. An Operation not permitted denial exits 77 as BLOCKED by sandbox,
# without running tests or claiming a test verdict. Rerun this same command
# on the daemon host, outside the agent sandbox, using commands.test.
# Other probe errors fail closed; actual test failures still exit 1.
#
# Exit status: 0 all selected scripts passed (or --list), 1 a script or
# non-sandbox host capability probe failed, 2 usage error, missing runner, or
# probe temporary-directory creation failure, 77 sandbox-blocked host capabilities.
#
# The gate reads commands.test only from the default-branch copy of
# .no-mistakes.yaml, so a change here takes effect for runs after it lands.
set -u

# launchd starts the no-mistakes daemon with a soft file-descriptor limit of
# 256 on macOS. The focused runner can legitimately exceed that while it
# checks the portable shard coverage, so raise only this test process tree.
ulimit -n 4096 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/bin/fm-test-run.sh"
# Same bound bin/fm-test-run.sh applies to --changed; see its header for the
# measurement it is derived from.
PER_SCRIPT_TIMEOUT_SECS=1500
FALLBACK_TESTS=(tests/fm-nm-test-contract.test.sh tests/fm-test-run.test.sh)

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-nm-test: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-nm-test: %s\n' "$*" >&2
}

LIST_ONLY=0
BASE_REF=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || die "--base needs a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

cd "$ROOT" || exit 2

ref_exists() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1
}

resolve_base() {
  local candidate
  if [ -n "$BASE_REF" ]; then
    ref_exists "$BASE_REF" || die "base ref not found: $BASE_REF"
    return 0
  fi
  for candidate in origin/main main; do
    if ref_exists "$candidate"; then
      BASE_REF=$candidate
      return 0
    fi
  done
  log "no base ref found (tried origin/main and main); only working-tree changes are considered"
  return 0
}

changed_paths() {
  if [ -n "$BASE_REF" ]; then
    git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null \
      || log "no merge base with $BASE_REF; only working-tree changes are considered"
  fi
  git diff --name-only HEAD 2>/dev/null || true
  git ls-files --others --exclude-standard 2>/dev/null || true
}

focused_tests() {
  local path=$1 name candidate="" matches count
  name=$(basename "$path")
  case "$path" in
    tests/*.test.sh) candidate=$path ;;
    bin/backends/*.sh) candidate="tests/fm-backend-${name%.sh}.test.sh" ;;
  esac
  if [ -n "$candidate" ] && [ -f "$ROOT/$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  case "$path" in
    bin/*) candidate="tests/${name%.*}.test.sh" ;;
    *) candidate= ;;
  esac
  if [ -n "$candidate" ] && [ -f "$ROOT/$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  matches=$(grep -Fl -- "$name" tests/*.test.sh 2>/dev/null | LC_ALL=C sort -u)
  count=$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')
  if [ "$count" -gt 0 ] && [ "$count" -le 8 ]; then
    printf '%s\n' "$matches"
  else
    log "no focused test for $path (consumer matches: $count); running fallback contract tests"
    printf '%s\n' "${FALLBACK_TESTS[@]}"
  fi
}

select_tests() {
  local path selected
  resolve_base
  selected=$(
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      focused_tests "$path"
    done < <(changed_paths) | LC_ALL=C sort -u
  )
  if [ -n "$selected" ]; then
    printf '%s\n' "$selected"
    return 0
  fi
  log "no focused test maps to the changes; running the fallback contract tests"
  printf '%s\n' "${FALLBACK_TESTS[@]}"
}

SELECTION=$(select_tests) || exit 2

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "$SELECTION"
  exit 0
fi

[ -x "$RUNNER" ] || die "test runner is missing or not executable: $RUNNER"

# Probe capabilities before tests can turn a denied process query or socket into
# an assertion failure. Never classify arbitrary test output as sandbox-blocked:
# a real assertion failure may legitimately mention either tool or that error.
check_host() {
  local probe_dir output rc
  output=$(ps -p "$$" -o pid= 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    host_error ps "$rc" "$output"
  fi
  command -v tmux >/dev/null 2>&1 || return 0
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-host.XXXXXX") || exit 2
  output=$(TMUX='' tmux -f /dev/null -S "$probe_dir/socket" new-session -d -s probe 'exec sleep 30' 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    output=$(TMUX='' tmux -f /dev/null -S "$probe_dir/socket" kill-server 2>&1)
    rc=$?
  fi
  # The probe creates only its socket inside this fresh private directory.
  rmdir "$probe_dir" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    host_error tmux "$rc" "$output"
  fi
}

host_error() {
  local tool=$1 rc=$2 output=$3
  case "$output" in
    *"Operation not permitted"*)
      log "BLOCKED by sandbox: $tool: $output"
      log "No tests ran. Rerun bin/fm-nm-test.sh on the no-mistakes daemon host outside the agent sandbox (commands.test); this is not a test failure or a pass."
      exit 77
      ;;
    *)
      log "host capability check failed: $tool (exit $rc): $output"
      exit 1
      ;;
  esac
}

check_host

total=$(printf '%s\n' "$SELECTION" | wc -l | tr -d ' ')
log "running $total test script(s) one at a time"
failed=()
while IFS= read -r script; do
  [ -n "$script" ] || continue
  if ! (
    while IFS= read -r key; do
      unset "$key"
    done < <(compgen -e FM_)
    exec "$RUNNER" --per-script-timeout-secs "$PER_SCRIPT_TIMEOUT_SECS" "$script"
  ); then
    failed+=("$script")
  fi
done <<<"$SELECTION"

if [ "${#failed[@]}" -gt 0 ]; then
  log "FAILED ${#failed[@]} of $total: ${failed[*]}"
  exit 1
fi
log "all $total passed"
