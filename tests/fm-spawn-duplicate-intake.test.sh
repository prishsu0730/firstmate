#!/usr/bin/env bash
# Behavior tests for same-logical-change duplicate prevention at spawn
# (bin/fm-duplicate-intake.sh, called by bin/fm-spawn.sh).
#
# Each case builds an isolated firstmate home and a real git project, records an
# earlier open task's meta by hand (no worker is started for it), and then spawns
# a second task whose brief names a commit. The spawn side runs the real
# fm-spawn.sh against a fake tmux and a no-op treehouse, so a refusal is proven
# by its consequence: no task record, no launch brief, and nothing typed into a
# pane, which is the only way a second worker could open a second PR.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-duplicate-intake)
GUARD="$ROOT/bin/fm-duplicate-intake.sh"
OLD_ID=old-change-a1
NEW_ID=new-change-b2

GIT_ID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# make_case <name>: home + project (with origin and a pane worktree) + fake bin.
# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG.
make_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
}

# add_open_task <id> [branch] [intent]: an earlier open ship task whose branch
# holds one commit of its own. Prints that commit's full SHA.
add_open_task() {
  local id=$1 branch=${2:-fm/$1} intent=${3:-earlier work for $1} twt
  twt="$CASE_DIR/$id-wt"
  git -C "$PROJ_DIR" worktree add --quiet -b "$branch" "$twt" || fail "could not add worktree for $id"
  printf 'change for %s\n' "$id" > "$twt/change.txt"
  git -C "$twt" add change.txt
  git -C "$twt" "${GIT_ID[@]}" commit -qm "change for $id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$twt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "branch=$branch"
  fm_test_spawn_brief "$HOME_DIR" "$id" "$intent"
  git -C "$twt" rev-parse HEAD
}

# write_new_brief <intent>: the new task's brief.
write_new_brief() {
  fm_test_spawn_brief "$HOME_DIR" "$NEW_ID" "$1"
}

spawn_new() {
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$NEW_ID" "$PROJ_DIR" \
    --mode no-mistakes --yolo off "$@"
}

guard() {
  "$GUARD" "$NEW_ID" "$PROJ_DIR" "$HOME_DIR/data/$NEW_ID/brief.md" \
    --state "$HOME_DIR/state" --data "$HOME_DIR/data" "$@" 2>&1
}

assert_not_launched() {
  [ ! -e "$HOME_DIR/state/$NEW_ID.meta" ] || fail "$1: a task record was written for $NEW_ID"
  [ ! -e "$HOME_DIR/data/$NEW_ID/launch-brief.md" ] || fail "$1: a launch brief was rendered for $NEW_ID"
  [ ! -s "$LAUNCH_LOG" ] || fail "$1: a worker launch was typed into a pane"
}

test_second_spawn_naming_same_commit_is_refused() {
  local sha out status
  make_case refuse
  sha=$(add_open_task "$OLD_ID")
  write_new_brief "Continue the work in commit ${sha:0:7} under a new name."

  out=$(spawn_new)
  status=$?
  expect_code 1 "$status" "second spawn for the same commit must be refused"
  assert_contains "$out" "$OLD_ID" "refusal does not name the earlier task"
  assert_contains "$out" "${sha:0:7}" "refusal does not name the commit"
  assert_contains "$out" "--supersedes" "refusal does not offer the supersede flag"
  assert_not_launched "refused spawn"
  pass "duplicate task under a different name is refused before any worker or PR can exist"
}

test_full_length_sha_is_matched_too() {
  local sha out status
  make_case refuse-full
  sha=$(add_open_task "$OLD_ID")
  write_new_brief "Rework $sha please."

  out=$(spawn_new)
  status=$?
  expect_code 1 "$status" "a 40-character SHA must match"
  assert_contains "$out" "$OLD_ID" "refusal does not name the earlier task"
  pass "a full 40-character SHA is matched"
}

test_supersedes_proceeds_and_records_link() {
  local sha out status
  make_case supersedes
  sha=$(add_open_task "$OLD_ID")
  write_new_brief "Continue the work in commit ${sha:0:7} under a new name."

  out=$(spawn_new --supersedes "$OLD_ID")
  status=$?
  expect_code 0 "$status" "--supersedes must let the spawn proceed: $out"
  assert_grep "supersedes=$OLD_ID" "$HOME_DIR/state/$NEW_ID.meta" "meta does not record the link"
  assert_contains "$out" "supersedes $OLD_ID" "no notice names the superseded task"
  pass "--supersedes proceeds and records supersedes= in the new task's meta"
}

test_supersedes_excuses_only_the_named_task() {
  local sha out status
  make_case supersedes-other
  sha=$(add_open_task "$OLD_ID")
  add_open_task unrelated-c3 >/dev/null
  write_new_brief "Continue the work in commit ${sha:0:7}."

  out=$(spawn_new --supersedes unrelated-c3)
  status=$?
  expect_code 1 "$status" "superseding a different task must not excuse the collision"
  assert_contains "$out" "$OLD_ID" "refusal does not name the colliding task"
  assert_not_launched "wrong --supersedes"
  pass "--supersedes excuses only the task it names"
}

test_allow_duplicate_proceeds() {
  local sha out status
  make_case allow
  sha=$(add_open_task "$OLD_ID")
  write_new_brief "Continue the work in commit ${sha:0:7}."

  out=$(spawn_new --allow-duplicate)
  status=$?
  expect_code 0 "$status" "--allow-duplicate must let the spawn proceed: $out"
  assert_contains "$out" "--allow-duplicate" "no notice reports the overridden match"
  [ -f "$HOME_DIR/state/$NEW_ID.meta" ] || fail "no task record for the allowed duplicate"
  assert_no_grep "^supersedes=" "$HOME_DIR/state/$NEW_ID.meta" "--allow-duplicate must not record a supersede link"
  pass "--allow-duplicate proceeds without recording a link"
}

test_unrelated_tasks_print_nothing() {
  local out status
  make_case unrelated
  add_open_task "$OLD_ID" >/dev/null
  write_new_brief "Add a different feature entirely."

  out=$(spawn_new)
  status=$?
  expect_code 0 "$status" "unrelated spawn must succeed: $out"
  assert_not_contains "$out" "already carries" "unrelated spawn printed a collision message"
  assert_not_contains "$out" "--supersedes" "unrelated spawn printed the supersede hint"
  assert_not_contains "$out" "$OLD_ID" "unrelated spawn mentioned the other task"
  assert_not_contains "$out" "has the same captain intent" "unrelated spawn printed a similarity warning"
  pass "unrelated tasks produce no warning and no refusal"
}

test_sha_only_in_closed_task_is_not_refused() {
  local sha out status
  make_case closed
  sha=$(add_open_task "$OLD_ID")
  fm_write_meta "$HOME_DIR/state/$OLD_ID.meta" \
    "window=firstmate:fm-$OLD_ID" "endpoint_task_id=$OLD_ID" "worktree=$CASE_DIR/$OLD_ID-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "branch=fm/$OLD_ID" "pr=https://github.com/example/repo/pull/12"
  fm_pr_url_parse "https://github.com/example/repo/pull/12" || fail "fixture PR URL did not parse"
  # The marker writer sets umask 077, so run it in a subshell.
  ( fm_pr_poll_merge_mark_notified "$HOME_DIR/state" "$OLD_ID" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" ) || fail "could not record the merge marker"
  write_new_brief "Follow up on the landed commit ${sha:0:7}."

  out=$(guard)
  status=$?
  expect_code 0 "$status" "a task whose PR merged must not collide: $out"

  rm -f "$HOME_DIR/state/$OLD_ID.pr-poll-merge-notified" "$HOME_DIR/state/$OLD_ID.meta"
  out=$(guard)
  status=$?
  expect_code 0 "$status" "a torn-down task (no record) must not collide: $out"
  pass "a commit present only in a merged or torn-down task is not refused"
}

test_pr_head_alone_collides() {
  local sha out status
  make_case pr-head
  sha=$(add_open_task "$OLD_ID")
  # The branch is gone locally (pruned after the push); only the recorded PR
  # head still carries the commit, and the object is still in the repository.
  fm_write_meta "$HOME_DIR/state/$OLD_ID.meta" \
    "window=firstmate:fm-$OLD_ID" "endpoint_task_id=$OLD_ID" "worktree=$CASE_DIR/gone-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "branch=fm/pruned-branch" \
    "pr=https://github.com/example/repo/pull/13" "pr_head=$sha"
  write_new_brief "Rework ${sha:0:9}."

  out=$(guard)
  status=$?
  expect_code 1 "$status" "a recorded PR head must collide"
  assert_contains "$out" "$OLD_ID" "refusal does not name the task"
  assert_contains "$out" "open pull request head" "refusal does not say the PR head carries it"
  pass "a commit contained only in a recorded PR head is refused"
}

test_commit_already_on_base_is_not_a_collision() {
  local base_sha out status
  make_case base
  add_open_task "$OLD_ID" >/dev/null
  base_sha=$(git -C "$PROJ_DIR" rev-parse main)
  write_new_brief "Start from main at ${base_sha:0:7}."

  out=$(guard)
  status=$?
  expect_code 0 "$status" "a commit on the base branch is in every task and must not collide: $out"

  git -C "$PROJ_DIR" fetch --quiet origin
  out=$(guard)
  status=$?
  expect_code 0 "$status" "the same must hold once origin's remote-tracking refs exist: $out"
  pass "a commit already on the base branch is never a duplicate"
}

test_non_commit_hex_is_ignored() {
  local out status
  make_case non-commit
  add_open_task "$OLD_ID" >/dev/null
  write_new_brief "Status at 1791870593 for gate d3979e0d8bb7, date 20261013, word defaced."

  out=$(guard)
  status=$?
  expect_code 0 "$status" "numbers and ids that are not commits must be ignored: $out"
  [ -z "$out" ] || fail "non-commit hex produced output: $out"
  pass "hex-looking text that is not a commit is ignored silently"
}

test_other_projects_tasks_are_ignored() {
  local sha out status other
  make_case other-project
  sha=$(add_open_task "$OLD_ID")
  other="$CASE_DIR/other-project-clone"
  fm_git_init_commit "$other"
  sed -i.bak "s#^project=.*#project=$other#" "$HOME_DIR/state/$OLD_ID.meta" && rm -f "$HOME_DIR/state/$OLD_ID.meta.bak"
  write_new_brief "Rework ${sha:0:7}."

  out=$(guard)
  status=$?
  expect_code 0 "$status" "a task in another project must not collide: $out"
  pass "tasks of other projects are not compared"
}

test_title_similarity_only_warns() {
  local out status
  make_case title
  add_open_task "$OLD_ID" fm/$OLD_ID "Add the garden map screen" >/dev/null
  write_new_brief "  add the GARDEN  map   screen "

  out=$(spawn_new)
  status=$?
  expect_code 0 "$status" "title similarity must never refuse: $out"
  assert_contains "$out" "has the same captain intent as open task $OLD_ID" "no similarity warning printed"
  [ -f "$HOME_DIR/state/$NEW_ID.meta" ] || fail "a similarity warning must not stop the spawn"
  pass "a title-only similarity prints a warning and spawns"
}

test_flags_are_single_ship_only() {
  local out status
  make_case flags
  write_new_brief "Unrelated work."

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$NEW_ID" "$PROJ_DIR" --scout --supersedes "$OLD_ID")
  status=$?
  expect_code 1 "$status" "--supersedes on a scout must be refused"
  assert_contains "$out" "apply only to ship spawns" "scout refusal text missing"

  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$NEW_ID" --relaunch --allow-duplicate)
  status=$?
  expect_code 1 "$status" "--allow-duplicate on a relaunch must be refused"
  assert_contains "$out" "fresh ship spawn" "relaunch refusal text missing"

  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
    "$NEW_ID=$PROJ_DIR" other-d4="$PROJ_DIR" --mode no-mistakes --yolo off --supersedes "$OLD_ID")
  status=$?
  expect_code 1 "$status" "--supersedes on a batch must be refused"
  assert_contains "$out" "single-task only" "batch refusal text missing"

  out=$(spawn_new --supersedes)
  status=$?
  expect_code 1 "$status" "--supersedes without a value must be refused"
  pass "the flags are refused on scouts, relaunches, batches, and when empty"
}

test_helper_usage_errors() {
  local out status
  make_case helper-usage
  write_new_brief "Anything."

  out=$("$GUARD" "$NEW_ID" "$PROJ_DIR" "$HOME_DIR/data/$NEW_ID/brief.md" 2>&1)
  status=$?
  expect_code 2 "$status" "a missing --state is a usage error"

  out=$(guard --supersedes "$NEW_ID")
  status=$?
  expect_code 2 "$status" "a task cannot supersede itself"
  assert_contains "$out" "cannot supersede itself" "self-supersede message missing"

  out=$("$GUARD" --help)
  status=$?
  expect_code 0 "$status" "--help must succeed"
  assert_contains "$out" "Usage: fm-duplicate-intake.sh" "--help missing usage"
  pass "the helper refuses malformed invocations and documents itself"
}

test_second_spawn_naming_same_commit_is_refused
test_full_length_sha_is_matched_too
test_supersedes_proceeds_and_records_link
test_supersedes_excuses_only_the_named_task
test_allow_duplicate_proceeds
test_unrelated_tasks_print_nothing
test_sha_only_in_closed_task_is_not_refused
test_pr_head_alone_collides
test_commit_already_on_base_is_not_a_collision
test_non_commit_hex_is_ignored
test_other_projects_tasks_are_ignored
test_title_similarity_only_warns
test_flags_are_single_ship_only
test_helper_usage_errors
