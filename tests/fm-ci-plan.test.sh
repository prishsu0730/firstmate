#!/usr/bin/env bash
# Contract tests for bin/fm-ci-plan.sh - the planner that decides which
# behavior-test lanes a CI run executes.
#
# Origin: a pull request used to run every test shard, so a one-line doc fix
# cost the same Actions minutes as a change to the watcher. These tests hold
# both halves of the contract: a lane runs only the tests a change can affect,
# and every doubt (a shared core file, an unmappable path, a runner error)
# resolves to the full suite rather than a skipped test.
#
# Each case builds a throwaway git repository holding a copy of the planner and
# a stand-in for bin/fm-test-run.sh that answers the same --list queries from
# canned lanes, so real diffs drive the planner through its public output. The
# last cases run the planner against the real runner in a clone of this
# repository to prove the two agree on the live lane inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLANNER="$ROOT/bin/fm-ci-plan.sh"

assert_present "$PLANNER" "bin/fm-ci-plan.sh is missing"
[ -x "$PLANNER" ] || fail "bin/fm-ci-plan.sh must be executable"
command -v jq >/dev/null 2>&1 || fail "jq is required"

PLAN_OUT=
PLAN_ERR=
PLAN_CODE=

git_fx() {  # <repo> <git args...>
  local repo=$1
  shift
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

# make_fixture: print a repo whose main carries the planner, a stand-in runner,
# and five canned test scripts, checked out on a fresh feature branch.
#
# Lanes the stand-in lists: parallel-1 {a}, parallel-2 {b}, serial 1of2 {c},
# serial 2of2 {d}, and the real-herdr-gated family {h}. The selection it
# answers for --changed comes from .git/selection; .git/runner-fail makes it
# error the way the real runner does for a path it cannot map.
make_fixture() {
  local repo t
  repo=$(fm_test_tmproot ci-plan) || fail "could not create a fixture root"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/bin" "$repo/tests" "$repo/docs"
  cp "$PLANNER" "$repo/bin/fm-ci-plan.sh"
  cat >"$repo/bin/fm-test-run.sh" <<'RUNNER'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$*" in
  "--list-lanes")
    printf '%s\n' portable-parallel-1 portable-parallel-2 portable-serial \
      portable-serial-1of2 portable-serial-2of2 real-herdr-gated
    ;;
  "--list --lane portable-parallel-1") echo tests/a.test.sh ;;
  "--list --lane portable-parallel-2") echo tests/b.test.sh ;;
  "--list --lane portable-serial-1of2") echo tests/c.test.sh ;;
  "--list --lane portable-serial-2of2") echo tests/d.test.sh ;;
  "--list --family real-herdr-gated") echo tests/h.test.sh ;;
  "--list --changed --base "*)
    [ ! -f "$ROOT/.git/runner-fail" ] || { echo 'no changed-test mapping for source path: x' >&2; exit 1; }
    cat "$ROOT/.git/selection" 2>/dev/null
    exit 0
    ;;
  *) echo "stand-in runner: unexpected call: $*" >&2; exit 3 ;;
esac
RUNNER
  chmod +x "$repo/bin/fm-test-run.sh" "$repo/bin/fm-ci-plan.sh"
  for t in a b c d h z; do
    printf '#!/usr/bin/env bash\n' >"$repo/tests/$t.test.sh"
  done
  printf 'base\n' >"$repo/docs/notes.md"
  printf 'base\n' >"$repo/bin/fm-foo.sh"
  printf 'base\n' >"$repo/bin/fm-bar.sh"
  printf 'base\n' >"$repo/bin/fm-spawn.sh"
  git_fx "$repo" add -A
  git_fx "$repo" commit -qm base
  git_fx "$repo" checkout -q -b feature
  : >"$repo/.git/selection"
  printf '%s\n' "$repo"
}

change() {  # <repo> <paths...>: edit the paths and commit them
  local repo=$1 p
  shift
  for p in "$@"; do
    mkdir -p "$(dirname "$repo/$p")"
    printf '# change\n' >>"$repo/$p"
  done
  git_fx "$repo" add -A
  git_fx "$repo" commit -qm change
}

select_tests() {  # <repo> <tests...>: what the stand-in runner will select
  local repo=$1
  shift
  printf '%s\n' "$@" >"$repo/.git/selection"
}

plan() {  # <repo> <planner args...>
  local repo=$1
  shift
  PLAN_OUT=$(cd "$repo" && "$repo/bin/fm-ci-plan.sh" "$@" 2>"$repo/.git/plan-stderr")
  PLAN_CODE=$?
  PLAN_ERR=$(cat "$repo/.git/plan-stderr")
}

key() {  # <key>: one value from the last plan's key=value output
  printf '%s\n' "$PLAN_OUT" | sed -n "s/^$1=//p"
}

lane() {  # <lane>: that lane's selection from the last plan
  key lanes | jq -r --arg l "$1" '.[$l]'
}

all_lanes() {  # <selection>: every lane carries exactly this selection
  key lanes | jq -r --arg s "$1" '[.[] | select(. != $s)] | length'
}

pr() {  # <repo> [extra planner args...]
  local repo=$1
  shift
  plan "$repo" --event pull_request --base main "$@"
}

test_non_pull_request_events_run_the_full_suite() {
  local repo event
  repo=$(make_fixture)
  change "$repo" docs/notes.md
  for event in push schedule; do
    plan "$repo" --event "$event" --base main
    expect_code 0 "$PLAN_CODE" "$event plan"
    assert_equals full "$(key mode)" "$event runs the full suite"
    assert_equals "--lane portable-parallel-1" "$(lane portable-parallel-1)" "$event keeps the lane as it ran before"
    assert_equals "--lane portable-serial-2of2" "$(lane portable-serial-2of2)" "$event keeps every serial shard"
    assert_equals "--family real-herdr-gated" "$(lane real-herdr-gated)" "$event keeps the Herdr family"
    assert_equals true "$(key macos)" "$event runs the macOS job"
    assert_equals true "$(key tests)" "$event runs behavior tests"
  done
  pass "a push and the nightly schedule keep the full suite"
}

test_lane_inventory_excludes_the_unsharded_serial_lane() {
  local repo
  repo=$(make_fixture)
  plan "$repo" --event push --base main
  assert_equals "null" "$(lane portable-serial)" "the bare serial lane is not a CI lane"
  assert_equals 5 "$(key lanes | jq 'length')" "every CI lane is named, no more"
  pass "the plan names exactly the lanes CI runs"
}

test_draft_pull_requests_skip_every_heavy_lane() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-core-thing.sh
  select_tests "$repo" tests/a.test.sh
  pr "$repo" --draft true
  expect_code 0 "$PLAN_CODE" "draft plan"
  assert_equals draft "$(key mode)" "a draft PR is its own mode"
  assert_equals 0 "$(all_lanes '')" "every behavior lane is skipped on a draft"
  assert_equals false "$(key macos)" "the macOS job waits on a draft"
  assert_equals false "$(key tests)" "no behavior test runs on a draft"
  pass "a draft pull request skips behavior tests, Herdr, and macOS"
}

test_docs_only_change_skips_behavior_tests() {
  local repo
  repo=$(make_fixture)
  change "$repo" docs/notes.md README.md
  pr "$repo"
  assert_equals docs "$(key mode)" "a documentation-only PR is docs mode"
  assert_equals 0 "$(all_lanes '')" "no behavior lane runs for documentation"
  assert_equals false "$(key macos)" "documentation does not need the macOS job"
  assert_equals false "$(key tests)" "documentation runs no behavior test"
  pass "a documentation-only change skips behavior tests"
}

test_docs_that_a_test_reads_run_that_test() {
  local repo
  repo=$(make_fixture)
  change "$repo" docs/notes.md
  select_tests "$repo" tests/b.test.sh
  pr "$repo"
  assert_equals changed "$(key mode)" "a doc the runner maps to a test is not docs-only"
  assert_equals tests/b.test.sh "$(lane portable-parallel-2)" "that test runs in its own lane"
  pass "a documentation file a test depends on still runs that test"
}

test_changed_files_run_only_their_tests_in_their_lanes() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-foo.sh
  select_tests "$repo" tests/a.test.sh tests/c.test.sh tests/h.test.sh
  pr "$repo"
  expect_code 0 "$PLAN_CODE" "changed plan"
  assert_equals changed "$(key mode)" "a mapped change is changed mode"
  assert_equals tests/a.test.sh "$(lane portable-parallel-1)" "parallel 1 runs its member"
  assert_equals "" "$(lane portable-parallel-2)" "parallel 2 has nothing to run"
  assert_equals tests/c.test.sh "$(lane portable-serial-1of2)" "serial 1 runs its member"
  assert_equals "" "$(lane portable-serial-2of2)" "serial 2 has nothing to run"
  assert_equals tests/h.test.sh "$(lane real-herdr-gated)" "the Herdr lane runs its member"
  assert_equals true "$(key tests)" "behavior tests run"
  pass "a changed file runs only its tests, each in the lane that owns it"
}

test_several_tests_in_one_lane_are_listed_together() {
  local repo
  repo=$(make_fixture)
  printf '#!/usr/bin/env bash\n' >"$repo/tests/e.test.sh"
  git_fx "$repo" add -A
  git_fx "$repo" commit -qm more
  change "$repo" bin/fm-foo.sh
  select_tests "$repo" tests/c.test.sh
  pr "$repo"
  assert_equals tests/c.test.sh "$(lane portable-serial-1of2)" "a single member is listed alone"
  pass "a lane's selection is its members of the changed set"
}

test_shared_core_files_run_the_full_suite() {
  local repo path
  for path in bin/fm-spawn.sh bin/fm-watch.sh bin/fm-teardown.sh bin/fm-brief-lib.sh \
    bin/fm-test-run.sh bin/fm-test-isolation-proof.sh bin/fm-ci-plan.sh \
    .github/workflows/ci.yml .github/workflows/other.yml tests/lib.sh; do
    repo=$(make_fixture)
    select_tests "$repo" tests/a.test.sh
    change "$repo" "$path"
    pr "$repo"
    assert_equals full "$(key mode)" "$path forces the full suite"
    assert_equals "--lane portable-serial-1of2" "$(lane portable-serial-1of2)" "$path keeps every shard"
    assert_contains "$(key reason)" "$path" "$path is named as the reason"
  done
  pass "each shared core file forces the full suite"
}

test_core_file_beats_a_draft_only_when_ready() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-spawn.sh
  pr "$repo" --draft true
  assert_equals draft "$(key mode)" "a draft waits even for a core change"
  pr "$repo" --draft false
  assert_equals full "$(key mode)" "the ready run covers the core change in full"
  pass "a core change waits on a draft and runs in full once ready"
}

test_runner_error_falls_back_to_full() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-foo.sh
  : >"$repo/.git/runner-fail"
  pr "$repo"
  assert_equals full "$(key mode)" "an unmappable path never narrows the plan"
  assert_equals "--lane portable-parallel-2" "$(lane portable-parallel-2)" "every lane still runs"
  assert_contains "$(key reason)" "could not map" "the reason says the mapping failed"
  pass "a runner error falls back to the full suite"
}

test_empty_selection_for_a_script_change_runs_full() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-foo.sh
  pr "$repo"
  assert_equals full "$(key mode)" "nothing mapped to a changed script is not proof it is safe"
  assert_contains "$(key reason)" "bin/fm-foo.sh" "the script is named"
  pass "a changed script with no mapped test runs the full suite"
}

test_empty_selection_for_files_no_test_covers_skips_every_lane() {
  local repo
  repo=$(make_fixture)
  change "$repo" AGENTS.md assets/logo.txt
  pr "$repo"
  assert_equals docs "$(key mode)" "the runner owns the map, so its empty answer is trusted off bin/ and tests/"
  assert_equals 0 "$(all_lanes '')" "no lane runs"
  assert_equals false "$(key tests)" "no behavior test runs"
  pass "files no test covers skip every behavior lane"
}

test_selection_no_lane_owns_runs_full() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-foo.sh
  select_tests "$repo" tests/a.test.sh tests/z.test.sh
  pr "$repo"
  assert_equals full "$(key mode)" "a test no lane owns would otherwise never run"
  assert_contains "$(key reason)" "tests/z.test.sh" "the unowned test is named"
  pass "a selected test that no lane owns runs the full suite"
}

test_selection_that_is_not_a_test_runs_full() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-foo.sh
  select_tests "$repo" 'tests/a.test.sh; touch /tmp/pwn'
  pr "$repo"
  assert_equals full "$(key mode)" "a malformed selection never reaches a lane argument"
  pass "a selection entry that is not an existing test runs the full suite"
}

test_deleted_or_moved_source_runs_full() {
  local repo
  repo=$(make_fixture)
  git_fx "$repo" mv bin/fm-bar.sh bin/fm-baz.sh
  git_fx "$repo" commit -qm move
  select_tests "$repo" tests/a.test.sh
  pr "$repo"
  assert_equals full "$(key mode)" "a moved script can break its consumers"
  assert_contains "$(key reason)" "bin/fm-bar.sh" "the removed path is named"
  pass "a deleted or renamed script runs the full suite"
}

test_missing_base_runs_full() {
  local repo
  repo=$(make_fixture)
  change "$repo" docs/notes.md
  plan "$repo" --event pull_request --base origin/nowhere
  assert_equals full "$(key mode)" "an unreadable base never narrows the plan"
  pass "a missing base ref runs the full suite"
}

test_empty_diff_runs_full() {
  local repo
  repo=$(make_fixture)
  pr "$repo"
  assert_equals full "$(key mode)" "no changed paths proves nothing"
  pass "an empty diff runs the full suite"
}

test_macos_job_follows_shell_changes_and_its_own_suites() {
  local repo
  repo=$(make_fixture)
  change "$repo" bin/fm-foo.sh
  select_tests "$repo" tests/a.test.sh
  pr "$repo"
  assert_equals true "$(key macos)" "a changed shell file runs the stock-Bash parse sweep"

  repo=$(make_fixture)
  change "$repo" docs/notes.md
  select_tests "$repo" tests/a.test.sh
  pr "$repo"
  assert_equals false "$(key macos)" "a change with no shell file and none of its suites skips macOS"

  repo=$(make_fixture)
  change "$repo" docs/notes.md
  printf '#!/usr/bin/env bash\n' >"$repo/tests/fm-backend.test.sh"
  select_tests "$repo" tests/fm-backend.test.sh
  pr "$repo"
  assert_equals full "$(key mode)" "a selected test no lane owns runs full"
  assert_equals true "$(key macos)" "and macOS runs with it"
  pass "the macOS job runs for shell changes and for its own suites only"
}

test_output_is_github_output_shaped() {
  local repo line
  repo=$(make_fixture)
  change "$repo" bin/fm-foo.sh
  select_tests "$repo" tests/a.test.sh
  pr "$repo"
  while IFS= read -r line; do
    case "$line" in
      mode=*|reason=*|lanes=*|macos=*|tests=*) ;;
      *) fail "stdout carries a line GITHUB_OUTPUT would reject: $line" ;;
    esac
  done <<<"$PLAN_OUT"
  printf '%s\n' "$(key lanes)" | jq -e . >/dev/null || fail "lanes is not valid JSON"
  [ "$(printf '%s\n' "$PLAN_OUT" | wc -l | tr -d ' ')" = 5 ] || fail "stdout must be exactly five key=value lines"
  assert_contains "$PLAN_ERR" "mode=changed" "the human summary goes to stderr"
  pass "stdout is five GITHUB_OUTPUT lines and the summary goes to stderr"
}

test_usage_errors() {
  local repo
  repo=$(make_fixture)
  plan "$repo"
  expect_code 2 "$PLAN_CODE" "missing --event"
  plan "$repo" --event pull_request --draft maybe
  expect_code 2 "$PLAN_CODE" "bad --draft"
  plan "$repo" --event pull_request --nope
  expect_code 2 "$PLAN_CODE" "unknown flag"
  plan "$repo" --help
  expect_code 0 "$PLAN_CODE" "--help"
  assert_contains "$PLAN_ERR" "Modes:" "help documents the modes"
  pass "usage errors exit 2 and --help documents the modes"
}

# --- the real runner -----------------------------------------------------------

# real_clone: print a clone of this repository, on a branch off its HEAD, that
# carries the working-tree planner and runner so the two are tested together.
real_clone() {
  local dir
  dir=$(fm_test_tmproot ci-plan-real) || fail "could not create a clone root"
  git clone -q --local "$ROOT" "$dir/repo" || fail "could not clone the repository"
  git_fx "$dir/repo" checkout -q -b plan-base
  git_fx "$dir/repo" checkout -q -b plan-change
  cp "$ROOT/bin/fm-ci-plan.sh" "$ROOT/bin/fm-test-run.sh" "$dir/repo/bin/"
  cp "$ROOT/tests/fm-ci-plan.test.sh" "$dir/repo/tests/"
  git_fx "$dir/repo" add -A
  git_fx "$dir/repo" commit -qm "sync working tree" 2>/dev/null || true
  git_fx "$dir/repo" branch -f plan-base HEAD
  printf '%s\n' "$dir/repo"
}

real_plan() {  # <repo> [extra args...]
  local repo=$1
  shift
  PLAN_OUT=$(cd "$repo" && env -u FM_HOME -u FM_BACKEND "$repo/bin/fm-ci-plan.sh" --event pull_request --base plan-base "$@" 2>"$repo/.git/plan-stderr")
  PLAN_CODE=$?
  PLAN_ERR=$(cat "$repo/.git/plan-stderr")
}

test_real_runner_docs_only_change() {
  local repo
  repo=$(real_clone)
  change "$repo" README.md
  real_plan "$repo"
  expect_code 0 "$PLAN_CODE" "real docs plan"
  assert_equals docs "$(key mode)" "the real runner maps a README change to no test"
  assert_equals 0 "$(all_lanes '')" "no lane runs"
  pass "against the real runner a README change plans docs mode"
}

test_real_runner_narrows_a_mapped_change_and_covers_every_lane() {
  local repo selected union unowned
  repo=$(real_clone)
  change "$repo" bin/fm-brief.sh
  real_plan "$repo"
  expect_code 0 "$PLAN_CODE" "real changed plan"
  assert_equals changed "$(key mode)" "a mapped script change is changed mode"
  selected=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base plan-base | LC_ALL=C sort -u)
  union=$(key lanes | jq -r '.[] | select(. != "") | split(" ")[]' | LC_ALL=C sort -u)
  assert_equals "$selected" "$union" "the lanes together run exactly the runner's selection"
  unowned=$(key lanes | jq -r '.[] | select(startswith("--"))' | wc -l | tr -d ' ')
  assert_equals 0 "$unowned" "a changed plan never falls back to a whole lane"
  pass "against the real runner the lanes split the changed selection with nothing dropped"
}

test_real_runner_core_change_runs_every_lane_as_before() {
  local repo lanes expected
  repo=$(real_clone)
  change "$repo" bin/fm-spawn.sh
  real_plan "$repo"
  assert_equals full "$(key mode)" "a core change is full"
  lanes=$(key lanes | jq -r 'keys[]' | LC_ALL=C sort)
  expected=$(cd "$repo" && bin/fm-test-run.sh --list-lanes | grep -E '^(portable-parallel-[0-9]+|portable-serial-[0-9]+of[0-9]+|real-herdr-gated)$' | LC_ALL=C sort)
  assert_equals "$expected" "$lanes" "the plan names every lane the runner owns"
  pass "against the real runner a core change plans every lane in full"
}

test_non_pull_request_events_run_the_full_suite
test_lane_inventory_excludes_the_unsharded_serial_lane
test_draft_pull_requests_skip_every_heavy_lane
test_docs_only_change_skips_behavior_tests
test_docs_that_a_test_reads_run_that_test
test_changed_files_run_only_their_tests_in_their_lanes
test_several_tests_in_one_lane_are_listed_together
test_shared_core_files_run_the_full_suite
test_core_file_beats_a_draft_only_when_ready
test_runner_error_falls_back_to_full
test_empty_selection_for_a_script_change_runs_full
test_empty_selection_for_files_no_test_covers_skips_every_lane
test_selection_no_lane_owns_runs_full
test_selection_that_is_not_a_test_runs_full
test_deleted_or_moved_source_runs_full
test_missing_base_runs_full
test_empty_diff_runs_full
test_macos_job_follows_shell_changes_and_its_own_suites
test_output_is_github_output_shaped
test_usage_errors
test_real_runner_docs_only_change
test_real_runner_narrows_a_mapped_change_and_covers_every_lane
test_real_runner_core_change_runs_every_lane_as_before
