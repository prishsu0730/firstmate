#!/usr/bin/env bash
# Contract tests for bin/fm-nm-test.sh - the deterministic no-mistakes Test
# command that runs the colocated tests for the files a branch changes.
#
# Each case builds a throwaway git repository holding a copy of the wrapper, a
# recording stand-in for bin/fm-test-run.sh, and empty colocated test stubs, so
# the mapping, the fallback, the one-at-a-time execution, and the environment
# scrubbing are all observed through the wrapper's real interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-nm-test.sh"

assert_present "$WRAPPER" "bin/fm-nm-test.sh is missing"
[ -x "$WRAPPER" ] || fail "bin/fm-nm-test.sh must be executable"

FIXTURE_OUT=
FIXTURE_ERR=
FIXTURE_CODE=

git_fx() {  # <repo> <git args...>
  local repo=$1
  shift
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

# make_fixture: print a repo whose main carries the wrapper, a recording runner,
# and colocated tests, checked out on a fresh feature branch.
make_fixture() {
  local repo f
  repo=$(fm_test_tmproot nm-test) || fail "could not create a fixture root"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/bin/backends" "$repo/tests"
  cp "$WRAPPER" "$repo/bin/fm-nm-test.sh"
  cat >"$repo/bin/fm-test-run.sh" <<'RUNNER'
#!/usr/bin/env bash
# Recording stand-in for the real runner: log the call and its inherited paths.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script=${!#}
printf 'ARGS=%s|FM_HOME=%s|STATE=%s|CONFIG=%s\n' "$*" \
  "${FM_HOME-unset}" "${FM_STATE_OVERRIDE-unset}" "${FM_CONFIG_OVERRIDE-unset}" >>"$ROOT/runner.log"
if [ -f "$ROOT/.git/fm-fail-on" ] && grep -Fxq "$script" "$ROOT/.git/fm-fail-on"; then
  echo "stand-in runner: $script failed"
  exit 1
fi
exit 0
RUNNER
  chmod +x "$repo/bin/fm-test-run.sh" "$repo/bin/fm-nm-test.sh"
  for f in fm-foo fm-bar fm-backend-fm-be fm-poly fm-gone fm-nm-test-contract fm-test-run; do
    printf '#!/usr/bin/env bash\n' >"$repo/tests/$f.test.sh"
  done
  for f in bin/fm-foo.sh bin/fm-bar.sh bin/fm-orphan.sh bin/backends/fm-be.sh bin/fm-poly.mjs; do
    printf 'base\n' >"$repo/$f"
  done
  printf 'base\n' >"$repo/tests/lib.sh"
  mkdir -p "$repo/docs"
  printf 'base\n' >"$repo/docs/notes.md"
  git_fx "$repo" add -A
  git_fx "$repo" commit -qm base
  git_fx "$repo" checkout -q -b feature
  printf '%s\n' "$repo"
}

touch_and_commit() {  # <repo> <paths...>
  local repo=$1 p
  shift
  for p in "$@"; do
    mkdir -p "$(dirname "$repo/$p")"
    printf 'change\n' >>"$repo/$p"
  done
  git_fx "$repo" add -A
  git_fx "$repo" commit -qm change
}

run_wrapper() {  # <repo> <args...>; leaks FM_* paths on purpose
  local repo=$1
  shift
  FIXTURE_OUT=$(cd "$repo" && FM_HOME=/leak/home FM_STATE_OVERRIDE=/leak/state \
    FM_CONFIG_OVERRIDE=/leak/config "$repo/bin/fm-nm-test.sh" "$@" 2>"$repo/.git/fm-stderr")
  FIXTURE_CODE=$?
  FIXTURE_ERR=$(cat "$repo/.git/fm-stderr")
}

listed() {  # <repo> <args...> -> the --list selection, one path per line
  local repo=$1
  shift
  run_wrapper "$repo" --list "$@"
  expect_code 0 "$FIXTURE_CODE" "--list"
  printf '%s\n' "$FIXTURE_OUT"
}

test_bin_change_selects_its_colocated_test() {
  local repo sel
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-foo.sh
  sel=$(listed "$repo" --base main)
  assert_equals "tests/fm-foo.test.sh" "$sel" "a bin/ change selects only its colocated test"
  pass "bin/ change selects exactly the colocated test"
}

test_test_change_selects_itself() {
  local repo sel
  repo=$(make_fixture)
  touch_and_commit "$repo" tests/fm-bar.test.sh
  sel=$(listed "$repo" --base main)
  assert_equals "tests/fm-bar.test.sh" "$sel" "a tests/ change selects itself"
  pass "tests/ change selects itself"
}

test_selection_is_deduplicated_and_sorted() {
  local repo sel
  repo=$(make_fixture)
  touch_and_commit "$repo" tests/fm-foo.test.sh bin/fm-foo.sh bin/fm-bar.sh bin/fm-poly.mjs
  sel=$(listed "$repo" --base main)
  assert_equals $'tests/fm-bar.test.sh\ntests/fm-foo.test.sh\ntests/fm-poly.test.sh' "$sel" \
    "bin and test changes for one subject select it once, sorted"
  pass "selection is deduplicated and sorted"
}

test_extension_and_backend_mapping() {
  local repo sel
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-poly.mjs bin/backends/fm-be.sh
  sel=$(listed "$repo" --base main)
  assert_equals $'tests/fm-backend-fm-be.test.sh\ntests/fm-poly.test.sh' "$sel" \
    "bin extensions and backend names select their focused tests"
  pass "bin extensions and backend names map correctly"
}

test_unmapped_files_add_fallback() {
  local repo sel
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-foo.sh bin/fm-orphan.sh docs/notes.md tests/lib.sh
  sel=$(listed "$repo" --base main)
  assert_equals $'tests/fm-foo.test.sh\ntests/fm-nm-test-contract.test.sh\ntests/fm-test-run.test.sh' "$sel" "unmapped files add fallback alongside focused tests"
  pass "unmapped files add fallback alongside focused tests"
}

test_nothing_mapped_falls_back_to_the_two_contract_tests() {
  local repo sel
  repo=$(make_fixture)
  touch_and_commit "$repo" docs/notes.md bin/fm-orphan.sh
  sel=$(listed "$repo" --base main)
  assert_equals $'tests/fm-nm-test-contract.test.sh\ntests/fm-test-run.test.sh' "$sel" \
    "nothing mapped selects the bounded two-test fallback"
  pass "nothing mapped falls back to the two contract tests"
}

test_empty_diff_falls_back() {
  local repo sel
  repo=$(make_fixture)
  sel=$(listed "$repo" --base main)
  assert_equals $'tests/fm-nm-test-contract.test.sh\ntests/fm-test-run.test.sh' "$sel" \
    "an empty diff selects the bounded fallback"
  pass "empty diff falls back"
}

test_deleted_test_is_not_selected() {
  local repo sel
  repo=$(make_fixture)
  git_fx "$repo" rm -q tests/fm-gone.test.sh bin/fm-foo.sh
  git_fx "$repo" commit -qm remove
  sel=$(listed "$repo" --base main)
  assert_equals $'tests/fm-foo.test.sh\ntests/fm-nm-test-contract.test.sh\ntests/fm-test-run.test.sh' "$sel" "a deleted test adds fallback without selecting itself, a deleted source still selects its test"
  pass "deleted test is skipped"
}

test_uncommitted_and_untracked_changes_count() {
  local repo sel
  repo=$(make_fixture)
  printf 'edit\n' >>"$repo/bin/fm-foo.sh"
  printf '#!/usr/bin/env bash\n' >"$repo/tests/fm-new.test.sh"
  sel=$(listed "$repo" --base main)
  assert_equals $'tests/fm-foo.test.sh\ntests/fm-new.test.sh' "$sel" \
    "working-tree and untracked changes select their tests"
  pass "uncommitted and untracked changes count"
}

test_default_base_is_origin_main_then_main() {
  local repo sel
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-foo.sh
  # Only main exists here: the default base must still find it.
  sel=$(listed "$repo")
  assert_equals "tests/fm-foo.test.sh" "$sel" "default base falls back to main"
  # origin/main wins when present, so move it past the change.
  git_fx "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse HEAD)"
  sel=$(listed "$repo")
  assert_equals $'tests/fm-nm-test-contract.test.sh\ntests/fm-test-run.test.sh' "$sel" \
    "default base prefers origin/main over main"
  pass "default base is origin/main, then main"
}

test_no_resolvable_default_base_falls_back_with_a_warning() {
  local repo
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-foo.sh
  git_fx "$repo" branch -q -m main trunk
  run_wrapper "$repo" --list
  expect_code 0 "$FIXTURE_CODE" "unresolvable default base"
  assert_contains "$FIXTURE_OUT" "tests/fm-nm-test-contract.test.sh" "fallback selection printed"
  assert_contains "$FIXTURE_ERR" "no base ref" "the warning names the missing base"
  pass "no default base falls back with a warning"
}

test_explicit_unknown_base_is_refused() {
  local repo
  repo=$(make_fixture)
  run_wrapper "$repo" --list --base no-such-ref
  expect_code 2 "$FIXTURE_CODE" "explicit unknown --base"
  assert_contains "$FIXTURE_ERR" "no-such-ref" "the refusal names the bad ref"
  pass "explicit unknown base is refused"
}

test_runs_each_script_separately_with_clean_env() {
  local repo log
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-foo.sh bin/fm-bar.sh
  run_wrapper "$repo" --base main
  expect_code 0 "$FIXTURE_CODE" "run"
  log=$(cat "$repo/runner.log")
  assert_equals "2" "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" "one runner call per script"
  assert_contains "$log" "tests/fm-bar.test.sh|" "bar ran"
  assert_contains "$log" "tests/fm-foo.test.sh|" "foo ran"
  assert_not_contains "$log" "tests/fm-bar.test.sh tests/fm-foo.test.sh" "scripts are never batched"
  assert_not_contains "$log" "--changed" "the wrapper names scripts, never a changed/family/all selection"
  assert_not_contains "$log" "--all" "never the complete suite"
  assert_not_contains "$log" "--family" "never a family"
  assert_not_contains "$log" "/leak/" "FM_HOME, FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE must not reach a test"
  assert_contains "$log" "FM_HOME=unset|STATE=unset|CONFIG=unset" "all three paths stripped"
  assert_contains "$log" "--per-script-timeout-secs" "each script is time-bounded"
  pass "each script runs separately with the three paths stripped"
}

test_fallback_runs_the_two_contract_tests() {
  local repo log
  repo=$(make_fixture)
  touch_and_commit "$repo" docs/notes.md
  run_wrapper "$repo" --base main
  expect_code 0 "$FIXTURE_CODE" "fallback run"
  log=$(cat "$repo/runner.log")
  assert_equals "2" "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" "exactly two fallback calls"
  assert_contains "$log" "tests/fm-nm-test-contract.test.sh|" "contract test ran"
  assert_contains "$log" "tests/fm-test-run.test.sh|" "runner contract test ran"
  pass "fallback runs exactly the two contract tests"
}

test_failure_runs_the_rest_and_exits_nonzero() {
  local repo log
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-foo.sh bin/fm-bar.sh
  printf 'tests/fm-bar.test.sh\n' >"$repo/.git/fm-fail-on"
  run_wrapper "$repo" --base main
  assert_not_equals 0 "$FIXTURE_CODE" "a failing test must fail the command"
  log=$(cat "$repo/runner.log")
  assert_contains "$log" "tests/fm-foo.test.sh|" "later scripts still run after a failure"
  assert_contains "$FIXTURE_ERR" "FAILED 1 of 2: tests/fm-bar.test.sh" "the failing script is named"
  pass "a failure runs the rest and exits non-zero"
}

test_missing_runner_is_refused() {
  local repo
  repo=$(make_fixture)
  touch_and_commit "$repo" bin/fm-foo.sh
  rm "$repo/bin/fm-test-run.sh"
  run_wrapper "$repo" --base main
  assert_not_equals 0 "$FIXTURE_CODE" "missing runner must not pass silently"
  pass "missing runner is refused"
}

test_usage_errors() {
  local repo
  repo=$(make_fixture)
  run_wrapper "$repo" --bogus
  expect_code 2 "$FIXTURE_CODE" "unknown flag"
  run_wrapper "$repo" --help
  expect_code 0 "$FIXTURE_CODE" "--help"
  assert_contains "$FIXTURE_ERR" "fm-nm-test.sh" "help names the script"
  pass "usage errors and --help"
}

test_reference_consumers_are_bounded() {
  local repo sel i helper
  for helper in bin/fm-orphan.sh tests/lib.sh tests/git-config-helpers.sh docs/notes.md; do
    repo=$(make_fixture)
    for i in 8 7 6 5 4 3 2 1; do
      printf '. "${ROOT}/%s"\n' "$helper" >"$repo/tests/consumer-$i.test.sh"
    done
    git_fx "$repo" add -A
    git_fx "$repo" commit -qm consumers
    git_fx "$repo" branch -f main HEAD
    touch_and_commit "$repo" "$helper"
    run_wrapper "$repo" --list --base main
    expect_code 0 "$FIXTURE_CODE" "consumer selection"
    sel=$(printf 'tests/consumer-%s.test.sh\n' 1 2 3 4 5 6 7 8)
    assert_equals "$sel" "$FIXTURE_OUT" "eight consumers are sorted and selected"
    printf '. "${ROOT}/%s"\n' "$helper" >"$repo/tests/consumer-9.test.sh"
    git_fx "$repo" add -A
    git_fx "$repo" commit -qm ninth
    git_fx "$repo" branch -f main HEAD
    touch_and_commit "$repo" "$helper"
    run_wrapper "$repo" --list --base main
    assert_equals $'tests/fm-nm-test-contract.test.sh\ntests/fm-test-run.test.sh' "$FIXTURE_OUT" "over cap uses fallback"
    assert_contains "$FIXTURE_ERR" "$helper" "unmapped file is named"
  done
  pass "reference consumers are bounded for scripts, helpers, and other files"
}

test_reference_consumers_are_bounded

test_bin_change_selects_its_colocated_test
test_test_change_selects_itself
test_selection_is_deduplicated_and_sorted
test_extension_and_backend_mapping
test_unmapped_files_add_fallback
test_nothing_mapped_falls_back_to_the_two_contract_tests
test_empty_diff_falls_back
test_deleted_test_is_not_selected
test_uncommitted_and_untracked_changes_count
test_default_base_is_origin_main_then_main
test_no_resolvable_default_base_falls_back_with_a_warning
test_explicit_unknown_base_is_refused
test_runs_each_script_separately_with_clean_env
test_fallback_runs_the_two_contract_tests
test_failure_runs_the_rest_and_exits_nonzero
test_missing_runner_is_refused
test_usage_errors
