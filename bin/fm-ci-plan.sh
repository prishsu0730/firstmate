#!/usr/bin/env bash
# fm-ci-plan.sh - decide which behavior-test lanes a CI run executes, so a pull
# request pays only for the tests its changed files can affect.
#
# Usage:
#   fm-ci-plan.sh --event <github.event_name> [--draft true|false] [--base <ref>]
#   fm-ci-plan.sh --help
#
# Prints GITHUB_OUTPUT-style key=value lines on stdout (a human summary goes to
# stderr), so the workflow runs: bin/fm-ci-plan.sh ... >> "$GITHUB_OUTPUT"
#
#   mode=full|changed|docs|draft
#   reason=<one line>
#   lanes=<one-line JSON object: lane name -> selection>
#   macos=true|false     whether the stock-Bash macOS job runs
#   macos_parse=true|false   whether to run the stock-Bash parse sweep
#   macos_tests=<JSON array>  selected stock-Bash behavior suites
#   tests=true|false     whether any behavior lane runs (gates the timing job)
#
# A lane selection is "" (skip the lane), "--lane <name>" or
# "--family real-herdr-gated" (the lane exactly as the full suite runs it), or
# a space-separated list of tests/<name>.test.sh paths (only those members of
# the lane). Lane names are the runner's: portable-parallel-1, portable-parallel-2,
# portable-serial-<k>of<n>, and real-herdr-gated for the required Herdr lane.
#
# Modes:
#   full     every lane runs unchanged. Chosen for any event that is not a
#            pull request (a main push and the nightly schedule keep full
#            coverage), for a change to shared core files (CORE_PATTERNS),
#            for a deleted or renamed file except .md files at the repository
#            root or anywhere under docs/, and whenever the
#            plan cannot be proven: an unreadable diff, a selection error, an
#            unmapped path, or a selection no lane owns. Fail closed: every
#            doubt resolves to full, never to a skipped test.
#   changed  each lane runs only its members of the runner's own changed-file
#            selection (bin/fm-test-run.sh --list --changed). That runner is
#            the single owner of the path-to-test map; nothing here repeats it.
#            A lane left with nothing to run is skipped.
#   docs     the runner maps none of the changed files to a test (documentation,
#            assets, and the like), so no behavior lane runs. The runner owns
#            that map; nothing here lists documentation paths. A changed bin/
#            or tests/ file is never treated this way, because the runner
#            refuses an unmapped one rather than selecting nothing.
#   draft    a draft pull request. Behavior lanes and the macOS job wait for
#            ready_for_review, which triggers a fresh run.
#
# Lint, the test-coverage guard, and the repository invariants are not planned
# here: they are cheap and run in every mode.
#
# The macOS parse sweep runs for full or any changed shell file. Named
# behavior suites run for full or when selected in MACOS_TESTS. The job runs
# when either is needed. Draft skips both.
#
# --base defaults to origin/main. Exit status: 0 on any plan (including full
# reached by fallback), 2 on a usage error.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/bin/fm-test-run.sh"
HERDR_FAMILY=real-herdr-gated

# Paths whose change can affect any test, so the whole suite must run. The test
# runner, this planner, the workflow, and the shared libraries and entry points
# every lane leans on.
CORE_PATTERNS=(
  'bin/fm-*-lib.sh'
  'bin/fm-spawn.sh'
  'bin/fm-watch.sh'
  'bin/fm-teardown.sh'
  'bin/fm-test-run.sh'
  'bin/fm-test-isolation-proof.sh'
  'bin/fm-ci-plan.sh'
  '.github/workflows/*'
  'tests/lib.sh'
  'tests/fixtures.sh'
)

# The suites the macOS job runs under stock Bash 3.2 (see ci.yml).
MACOS_TESTS=(
  tests/fm-fleet-snapshot-view.test.sh
  tests/fm-bearings-snapshot.test.sh
  tests/fm-public-followup.test.sh
  tests/fm-watch-triage.test.sh
  tests/fm-fork-free-helpers.test.sh
  tests/fm-backend.test.sh
)

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-ci-plan: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-ci-plan: %s\n' "$*" >&2
}

EVENT=
DRAFT=false
BASE=origin/main

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      [ "$#" -ge 2 ] || die "--event needs a value"
      EVENT=$2
      shift 2
      ;;
    --draft)
      [ "$#" -ge 2 ] || die "--draft needs true or false"
      DRAFT=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || die "--base needs a git ref"
      BASE=$2
      shift 2
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

[ -n "$EVENT" ] || die "--event is required"
case "$DRAFT" in
  true|false) ;;
  *) die "--draft must be true or false, got: $DRAFT" ;;
esac
command -v jq >/dev/null 2>&1 || die "jq is required"
cd "$ROOT" || exit 2

# Lane inventory, in the order the runner lists them. The bare portable-serial
# lane is the unsharded whole and is not a CI lane.
LANES=()
HERDR_LANE=$HERDR_FAMILY
lane_args() {
  case "$1" in
    "$HERDR_LANE") printf -- '--family %s' "$HERDR_FAMILY" ;;
    *) printf -- '--lane %s' "$1" ;;
  esac
}
lane_members() {
  case "$1" in
    "$HERDR_LANE") "$RUNNER" --list --family "$HERDR_FAMILY" ;;
    *) "$RUNNER" --list --lane "$1" ;;
  esac
}

load_lanes() {
  local listed lane
  listed=$("$RUNNER" --list-lanes) || return 1
  LANES=()
  while IFS= read -r lane; do
    case "$lane" in
      portable-parallel-[0-9]*|portable-serial-[0-9]*of[0-9]*) LANES+=("$lane") ;;
    esac
  done <<<"$listed"
  [ "${#LANES[@]}" -gt 0 ] || return 1
  LANES+=("$HERDR_LANE")
}

# emit <mode> <reason> <macos_parse> <macos_tests_json> <lane>=<selection>...
# Selections are newline-free strings; jq builds the JSON so none is spliced in.
emit() {
  local mode=$1 reason=$2 macos_parse=$3 macos_tests=$4 macos=false any=false lane sel pair json='{}'
  shift 4
  if [ "$macos_parse" = true ] || [ "$macos_tests" != '[]' ]; then
    macos=true
  fi
  for pair in "$@"; do
    lane=${pair%%=*}
    sel=${pair#*=}
    [ -z "$sel" ] || any=true
    json=$(printf '%s' "$json" | jq -c --arg k "$lane" --arg v "$sel" '. + {($k): $v}') || exit 2
  done
  log "mode=$mode: $reason"
  printf 'mode=%s\nreason=%s\nlanes=%s\nmacos=%s\nmacos_parse=%s\nmacos_tests=%s\ntests=%s\n' "$mode" "$reason" "$json" "$macos" "$macos_parse" "$macos_tests" "$any"
}

# emit_uniform <mode> <reason> <macos> <full|none>
emit_uniform() {
  local mode=$1 reason=$2 macos=$3 kind=$4 lane suites='[]' pairs=()
  if [ "$kind" = full ]; then
    suites=$(printf '%s\n' "${MACOS_TESTS[@]}" | jq -Rsc 'split("\n")[:-1]')
  fi
  for lane in "${LANES[@]}"; do
    if [ "$kind" = full ]; then
      pairs+=("$lane=$(lane_args "$lane")")
    else
      pairs+=("$lane=")
    fi
  done
  emit "$mode" "$reason" "$macos" "$suites" "${pairs[@]}"
}

full_plan() {
  emit_uniform full "$1" true full
}

if ! load_lanes; then
  # No lane inventory means no lane names to key the plan by. The workflow
  # cannot run a lane it cannot name, so refuse loudly instead of guessing.
  die "could not read the runner's lane inventory"
fi

if [ "$EVENT" != pull_request ]; then
  full_plan "event $EVENT keeps the full suite"
  exit 0
fi

if [ "$DRAFT" = true ]; then
  emit_uniform draft "draft pull request; behavior tests wait for ready_for_review" false none
  exit 0
fi

# Changed paths: pure additions, edits, and deletions. Renames are split so a
# moved file counts as the deletion of its old path as well as the new one.
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  full_plan "base ref $BASE not found"
  exit 0
fi
if ! CHANGED=$(git diff --name-only --no-renames "$BASE...HEAD" 2>/dev/null); then
  full_plan "no merge base with $BASE"
  exit 0
fi
if ! REMOVED=$(git diff --name-only --no-renames --diff-filter=D "$BASE...HEAD" 2>/dev/null); then
  full_plan "could not read removed paths against $BASE"
  exit 0
fi
if [ -z "$CHANGED" ]; then
  full_plan "no changed paths against $BASE"
  exit 0
fi

path_matches() {
  local path=$1 pattern
  shift
  for pattern in "$@"; do
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if path_matches "$path" "${CORE_PATTERNS[@]}"; then
    full_plan "shared core file changed: $path"
    exit 0
  fi
done <<<"$CHANGED"

# A removed path cannot be mapped to the tests that read it: the file is gone,
# so the runner can only search test text for its old name and an indirect
# consumer is missed. Only a removed documentation file is proven safe to leave
# to that search; any other removal or rename runs the whole suite.
removal_is_doc_only() {
  case "$1" in
    docs/*.md) return 0 ;;
    */*) return 1 ;;
    *.md) return 0 ;;
  esac
  return 1
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if ! removal_is_doc_only "$path"; then
    full_plan "deleted or moved file may leave consumers broken: $path"
    exit 0
  fi
done <<<"$REMOVED"

if ! SELECTED=$("$RUNNER" --list --changed --base "$BASE" 2>/dev/null); then
  full_plan "the runner could not map the changed files to tests"
  exit 0
fi

# An unmappable selection never narrows the plan: every selected path must be a
# real test, and one the lane inventory owns, or the whole suite runs.
selected_ok=1
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    tests/*.test.sh) [ -f "$path" ] || selected_ok=0 ;;
    *) selected_ok=0 ;;
  esac
done <<<"$SELECTED"
if [ "$selected_ok" -ne 1 ]; then
  full_plan "the runner selected something that is not a test script"
  exit 0
fi

macos_parse=false
if printf '%s\n' "$CHANGED" | grep -q '\.sh$'; then
  macos_parse=true
fi

if [ -z "$SELECTED" ]; then
  # The runner exits cleanly with nothing only for files no test covers. For
  # source it dies instead, so an empty answer about bin/ or tests/ is a
  # contradiction and never proof that nothing needs to run.
  while IFS= read -r path; do
    case "$path" in
      bin/*|tests/*)
        full_plan "no test maps to a changed script, so nothing is proven safe to skip: $path"
        exit 0
        ;;
    esac
  done <<<"$CHANGED"
  emit_uniform docs "no test covers the changed files; no behavior lane runs" "$macos_parse" none
  exit 0
fi

SELECTED=$(printf '%s\n' "$SELECTED" | LC_ALL=C sort -u)
pairs=()
OWNED=
for lane in "${LANES[@]}"; do
  if ! members=$(lane_members "$lane" 2>/dev/null); then
    full_plan "could not list members of lane $lane"
    exit 0
  fi
  members=$(printf '%s\n' "$members" | LC_ALL=C sort -u)
  OWNED=$(printf '%s\n%s\n' "$OWNED" "$members")
  hit=$(LC_ALL=C comm -12 <(printf '%s\n' "$SELECTED") <(printf '%s\n' "$members") | tr '\n' ' ')
  pairs+=("$lane=${hit% }")
done

# Every selected test must belong to some lane, or it would silently not run.
unowned=$(LC_ALL=C comm -23 <(printf '%s\n' "$SELECTED") <(printf '%s\n' "$OWNED" | LC_ALL=C sort -u))
if [ -n "$unowned" ]; then
  full_plan "selected tests that no lane owns: $(printf '%s' "$unowned" | tr '\n' ' ')"
  exit 0
fi

macos_tests='[]'
for t in "${MACOS_TESTS[@]}"; do
  if printf '%s\n' "$SELECTED" | grep -Fxq "$t"; then
    macos_tests=$(printf '%s' "$macos_tests" | jq -c --arg t "$t" '. + [$t]')
  fi
done

count=$(printf '%s\n' "$SELECTED" | awk 'NF { n++ } END { print n+0 }')
emit changed "$count test(s) selected from the changed files" "$macos_parse" "$macos_tests" "${pairs[@]}"
