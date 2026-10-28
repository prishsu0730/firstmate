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
# Selection is the colocated test only, never a family, a suite walk, or a
# fixed list: a changed tests/<name>.test.sh selects itself, and a changed
# bin/<name>.<ext> selects tests/<name>.test.sh. Committed changes against the
# base, uncommitted changes, and untracked files all count. A path with no
# existing colocated test selects nothing. When nothing at all is selected the
# fallback is exactly tests/fm-nm-test-contract.test.sh and
# tests/fm-test-run.test.sh.
#
# Each selected script runs separately through bin/fm-test-run.sh, which owns
# bash invocation, fixture Git isolation, and the per-script time bound, with
# FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE removed from its
# environment. The remaining scripts still run after a failure. The command
# exits non-zero when any script fails, and the gate parks the Test step.
#
# Exit status: 0 all selected scripts passed (or --list), 1 a script failed,
# 2 usage error or missing runner.
#
# The gate reads commands.test only from the default-branch copy of
# .no-mistakes.yaml, so a change here takes effect for runs after it lands.
set -u

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

# Print the colocated test for one changed path, or nothing.
colocated_test() {
  local path=$1 name candidate
  case "$path" in
    tests/*/*) return 0 ;;
    tests/*.test.sh) candidate=$path ;;
    bin/*)
      name=$(basename "$path")
      candidate="tests/${name%.*}.test.sh"
      ;;
    *) return 0 ;;
  esac
  [ -f "$ROOT/$candidate" ] && printf '%s\n' "$candidate"
  return 0
}

select_tests() {
  local path selected
  resolve_base
  selected=$(
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      colocated_test "$path"
    done < <(changed_paths) | LC_ALL=C sort -u
  )
  if [ -n "$selected" ]; then
    printf '%s\n' "$selected"
    return 0
  fi
  log "no colocated test maps to the changes; running the fallback contract tests"
  printf '%s\n' "${FALLBACK_TESTS[@]}"
}

SELECTION=$(select_tests) || exit 2

if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "$SELECTION"
  exit 0
fi

[ -x "$RUNNER" ] || die "test runner is missing or not executable: $RUNNER"

total=$(printf '%s\n' "$SELECTION" | wc -l | tr -d ' ')
log "running $total test script(s) one at a time"
failed=()
while IFS= read -r script; do
  [ -n "$script" ] || continue
  if ! env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    "$RUNNER" --per-script-timeout-secs "$PER_SCRIPT_TIMEOUT_SECS" "$script"; then
    failed+=("$script")
  fi
done <<<"$SELECTION"

if [ "${#failed[@]}" -gt 0 ]; then
  log "FAILED ${#failed[@]} of $total: ${failed[*]}"
  exit 1
fi
log "all $total passed"
