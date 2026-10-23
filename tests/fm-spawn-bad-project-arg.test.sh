#!/usr/bin/env bash
# tests/fm-spawn-bad-project-arg.test.sh - a project argument that is not an
# existing directory (for example a bare repo name) is refused with one clear
# line, a nonzero exit, and no state change.
set -u

# The runner may source shared helpers while selecting/executing tests. This
# standalone process must load them into its own shell.
unset FM_TEST_LIB_SOURCED FM_TEST_FIXTURES_SOURCED

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-bad-project-arg)

HOME_DIR="$TMP_ROOT/home"
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$HOME_DIR" claude
fm_test_spawn_brief "$HOME_DIR" bad-arg-task
before=$(cd "$HOME_DIR" && find . -type f | LC_ALL=C sort | xargs cksum)

out=$(cd "$TMP_ROOT" && fm_test_run_spawn "$HOME_DIR" "$TMP_ROOT" "$FAKEBIN_DIR" bad-arg-task firstmate --mode no-mistakes --yolo off)
status=$?

[ "$status" -ne 0 ] || fail "a bare repo name should be refused, got exit 0: $out"
case "$out" in
*"project directory 'firstmate' is not an existing directory"*"projects/<name>"*) ;;
*) fail "refusal should name the bad value and the accepted forms: $out" ;;
esac
case "$out" in
*"No such file or directory"*) fail "the raw cd error leaked: $out" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "refusal should be one line: $out"
after=$(cd "$HOME_DIR" && find . -type f | LC_ALL=C sort | xargs cksum)
[ "$before" = "$after" ] || fail "the refused spawn changed state"
[ ! -e "$HOME_DIR/state/bad-arg-task.meta" ] || fail "a task record was published"
pass "a non-directory project argument is refused clearly, with nonzero exit and no state change"

printf 'all tests passed\n'
