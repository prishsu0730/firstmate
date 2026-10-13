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

# --- G4b: a task that only NAMES a commit is a claim -------------------------
#
# The cases above prove a commit already on another task's branch or PR head. The
# ones below prove the earlier window: two tasks name one commit before either
# has a branch holding it. The earlier task's own record (state/<id>.meta,
# written by the real spawn under the task-set lock) is the claim, so every case
# here drives the real fm-spawn.sh or fm-promote.sh rather than hand-writing the
# claim, except where a case needs a record shape a spawn cannot produce.

# floating_commit [message]: a commit object that no branch, tag, or worktree
# holds, so only a recorded claim can tell one task another already names it.
floating_commit() {
  local tree
  tree=$(git -C "$PROJ_DIR" rev-parse 'main^{tree}') || fail "project has no main tree"
  git -C "$PROJ_DIR" "${GIT_ID[@]}" commit-tree "$tree" -p main -m "${1:-floating change}"
}

# add_pane <name>: a pane worktree of its own, so two spawns never share one.
add_pane() {
  local path="$CASE_DIR/$1-pane"
  [ -d "$path" ] || git -C "$PROJ_DIR" worktree add --quiet -b "pane-$1" "$path" || fail "could not add pane $1"
  printf '%s\n' "$path"
}

# spawn_task <id> [fm-spawn flags]: a real fresh ship spawn from <id>'s brief.
spawn_task() {
  local id=$1 pane
  shift
  pane=$(add_pane "$id")
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off "$@"
}

claim_of() {  # <id>
  sed -n 's/^commits=//p' "$HOME_DIR/state/$1.meta" 2>/dev/null
}

# claim_holders <sha>: how many task records list <sha> in a commits= field.
claim_holders() {
  local n=0 meta
  for meta in "$HOME_DIR"/state/*.meta; do
    [ -f "$meta" ] || continue
    grep -q "^commits=.*$1" "$meta" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# task_records: how many task records the case home holds.
task_records() {
  local n=0 meta
  for meta in "$HOME_DIR"/state/*.meta; do
    [ -f "$meta" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

upper() {  # <text>
  printf '%s' "$1" | tr 'a-f' 'A-F'
}

# add_scout <id> <intent>: a scout task of the case project and its brief.
add_scout() {
  local id=$1 intent=$2
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$CASE_DIR/$id-scout-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=scout" "mode=scout" "yolo=off"
  fm_test_spawn_brief "$HOME_DIR" "$id" "$intent"
}

promote_scout() {  # <id> [fm-promote flags]
  local id=$1
  shift
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off "$@" 2>&1
}

# 1. Two tasks naming the same commit before either branch holds it.
test_two_tasks_naming_one_unbranched_commit_are_refused() {
  local variant x out status first second
  for variant in abbrev-then-full full-then-abbrev; do
    make_case "named-$variant"
    x=$(floating_commit "floating $variant")
    case $variant in
      abbrev-then-full) first=${x:0:7}; second=$x ;;
      full-then-abbrev) first=$x; second=${x:0:12} ;;
    esac
    fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land commit $first as its own change."
    out=$(spawn_task "$OLD_ID")
    status=$?
    expect_code 0 "$status" "$variant: the first task must spawn: $out"
    assert_equals "$x" "$(claim_of "$OLD_ID")" "$variant: the spawn must record the full SHA it names"

    write_new_brief "Rework commit $second under a new name."
    out=$(spawn_new)
    status=$?
    expect_code 1 "$status" "$variant: a second task naming the same commit must be refused"
    assert_contains "$out" "$OLD_ID already carries commit" "$variant: refusal does not name the first task"
    assert_contains "$out" "--supersedes" "$variant: refusal does not offer the supersede flag"
    assert_not_launched "$variant: second task"
    assert_equals 1 "$(claim_holders "$x")" "$variant: exactly one task may hold the claim"
  done
  pass "a commit named by an open task is a claim before any branch holds it, in full or abbreviated form"
}

# 2. A scout promoted into the same logical work.
test_promotion_is_refused_for_a_commit_another_task_holds() {
  local x out status
  make_case promote-dup
  x=$(floating_commit "floating promote")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land commit ${x:0:8}."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "the owning task must spawn: $out"
  add_scout scout-e5 "Investigate and then ship commit ${x:0:8} as a fix."

  out=$(promote_scout scout-e5)
  status=$?
  expect_code 1 "$status" "promoting into a held commit must be refused"
  assert_contains "$out" "$OLD_ID already carries commit" "promotion refusal does not name the holder"
  assert_grep "kind=scout" "$HOME_DIR/state/scout-e5.meta" "a refused promotion changed the task kind"
  assert_no_grep "commits=" "$HOME_DIR/state/scout-e5.meta" "a refused promotion recorded a claim"
  assert_absent "$HOME_DIR/data/scout-e5/ship-instructions.md" "a refused promotion wrote ship instructions"

  out=$(promote_scout scout-e5 --supersedes "$OLD_ID")
  status=$?
  expect_code 0 "$status" "--supersedes must let the promotion proceed: $out"
  assert_grep "kind=ship" "$HOME_DIR/state/scout-e5.meta" "supersede promotion did not make the task a ship"
  assert_grep "supersedes=$OLD_ID" "$HOME_DIR/state/scout-e5.meta" "promotion did not record the superseded task"
  assert_equals "$x" "$(claim_of scout-e5)" "promotion did not record the commit it now owns"

  make_case promote-allow
  x=$(floating_commit "floating promote allow")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land commit ${x:0:8}."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "the owning task must spawn: $out"
  add_scout scout-e6 "Ship commit ${x:0:8}."
  out=$(promote_scout scout-e6 --allow-duplicate)
  status=$?
  expect_code 0 "$status" "--allow-duplicate must let the promotion proceed: $out"
  assert_contains "$out" "--allow-duplicate" "no notice reports the overridden match"
  assert_grep "kind=ship" "$HOME_DIR/state/scout-e6.meta" "overridden promotion did not make the task a ship"
  assert_no_grep "supersedes=" "$HOME_DIR/state/scout-e6.meta" "--allow-duplicate must not record a supersede link"
  assert_equals "$x" "$(claim_of scout-e6)" "overridden promotion did not record the commit"
  pass "promotion runs the same duplicate check, honours both overrides, and records the claim"
}

# 3. Uppercase commit identifiers.
test_uppercase_commit_identifiers_are_matched() {
  local x out status text
  make_case uppercase
  x=$(floating_commit "floating uppercase")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land commit ${x:0:8}."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "the owning task must spawn: $out"

  for text in "$(upper "${x:0:9}")" "$(upper "$x")"; do
    write_new_brief "Rework commit $text."
    out=$(spawn_new)
    status=$?
    expect_code 1 "$status" "uppercase $text must be refused like lowercase"
    assert_contains "$out" "$OLD_ID already carries commit" "uppercase refusal does not name the holder"
    assert_not_launched "uppercase $text"
  done

  # An uppercase claim is recorded as the lowercase full SHA a lowercase one is.
  make_case uppercase-record
  x=$(floating_commit "floating uppercase record")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land commit $(upper "${x:0:10}")."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "an uppercase first task must spawn: $out"
  assert_equals "$x" "$(claim_of "$OLD_ID")" "an uppercase mention must record the lowercase full SHA"
  pass "uppercase and lowercase commit identifiers are one claim"
}

# 4. Distinct legitimate work stays allowed.
test_distinct_legitimate_work_stays_allowed() {
  local base x y out status
  make_case legit
  base=$(git -C "$PROJ_DIR" rev-parse main)

  # A shared base commit is in every task and is never a claim.
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Build on base ${base:0:8} for the garden map."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "a task naming only the base commit must spawn: $out"
  assert_equals "" "$(claim_of "$OLD_ID")" "a base commit must not be recorded as a claim"
  write_new_brief "Build on base ${base:0:8} for the trail log."
  out=$(spawn_new)
  status=$?
  expect_code 0 "$status" "two tasks sharing only a base commit must both be allowed: $out"
  assert_not_contains "$out" "already carries" "a base commit produced a collision message"

  # Two different unbranched commits are two different changes.
  make_case legit-distinct
  x=$(floating_commit "floating one")
  y=$(floating_commit "floating two")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land ${x:0:8}."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "the first of two distinct changes must spawn: $out"
  write_new_brief "Land ${y:0:8}."
  out=$(spawn_new)
  status=$?
  expect_code 0 "$status" "a different commit is distinct work: $out"
  assert_equals "$x" "$(claim_of "$OLD_ID")" "the first task's claim changed"
  assert_equals "$y" "$(claim_of "$NEW_ID")" "the second task did not record its own commit"

  # A claimed commit that has since landed on the default branch is not work.
  make_case legit-landed
  x=$(floating_commit "floating landed")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land ${x:0:8}."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "the owning task must spawn: $out"
  git -C "$PROJ_DIR" merge --quiet --ff-only "$x" || fail "could not land the commit on main"
  git -C "$PROJ_DIR" push --quiet origin main || fail "could not publish main"
  git -C "$PROJ_DIR" fetch --quiet origin
  write_new_brief "Follow up on the landed ${x:0:8}."
  out=$(spawn_new)
  status=$?
  expect_code 0 "$status" "a landed commit must not collide: $out"
  assert_equals "" "$(claim_of "$NEW_ID")" "a landed commit must not be recorded as a claim"

  # The same with no remote-tracking ref at all: a local-only project lands on
  # its own checked-out branch, and a claim recorded before that landing frees.
  make_case legit-landed-local
  x=$(floating_commit "floating landed local")
  fm_write_meta "$HOME_DIR/state/$OLD_ID.meta" \
    "window=firstmate:fm-$OLD_ID" "endpoint_task_id=$OLD_ID" "worktree=$CASE_DIR/$OLD_ID-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "branch=fm/$OLD_ID" "commits=$x"
  write_new_brief "Rework ${x:0:8}."
  out=$(guard)
  status=$?
  expect_code 1 "$status" "an unlanded claim must still collide: $out"
  git -C "$PROJ_DIR" merge --quiet --ff-only "$x" || fail "could not land the commit locally"
  out=$(guard)
  status=$?
  expect_code 0 "$status" "a claim that landed on the checked-out branch must not collide: $out"
  assert_not_contains "$out" "commits=" "a landed commit was reported as still claimed"

  # A merged task, then a torn-down one, releases its claim.
  make_case legit-closed
  x=$(floating_commit "floating closed")
  fm_write_meta "$HOME_DIR/state/$OLD_ID.meta" \
    "window=firstmate:fm-$OLD_ID" "endpoint_task_id=$OLD_ID" "worktree=$CASE_DIR/$OLD_ID-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "branch=fm/$OLD_ID" "commits=$x" "pr=https://github.com/example/repo/pull/21"
  fm_pr_url_parse "https://github.com/example/repo/pull/21" || fail "fixture PR URL did not parse"
  ( fm_pr_poll_merge_mark_notified "$HOME_DIR/state" "$OLD_ID" \
    "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" ) || fail "could not record the merge marker"
  write_new_brief "Rework ${x:0:8}."
  out=$(guard)
  status=$?
  expect_code 0 "$status" "a merged task's claim must not collide: $out"
  rm -f "$HOME_DIR/state/$OLD_ID.pr-poll-merge-notified" "$HOME_DIR/state/$OLD_ID.meta"
  out=$(guard)
  status=$?
  expect_code 0 "$status" "a torn-down task's claim must not collide: $out"

  # Hex-looking words that are not commits are ignored, in either case.
  make_case legit-hex
  x=$(floating_commit "floating hex")
  fm_write_meta "$HOME_DIR/state/$OLD_ID.meta" \
    "window=firstmate:fm-$OLD_ID" "endpoint_task_id=$OLD_ID" "worktree=$CASE_DIR/$OLD_ID-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "branch=fm/$OLD_ID" "commits=$x"
  write_new_brief "Seen at 1791870593, gate d3979e0d8bb7, word DEADBEEF and defaced."
  out=$(guard)
  status=$?
  expect_code 0 "$status" "non-commit hex must be ignored: $out"
  [ -z "$out" ] || fail "non-commit hex produced output: $out"

  # A title-only match warns and still spawns even when the other task holds a claim.
  make_case legit-title
  x=$(floating_commit "floating title")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Add the garden map screen"$'\n'"Landing commit ${x:0:8}."
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "the owning task must spawn: $out"
  write_new_brief "  add the GARDEN  map screen "
  out=$(spawn_new)
  status=$?
  expect_code 0 "$status" "title similarity alone must never refuse: $out"
  assert_contains "$out" "has the same captain intent as open task $OLD_ID" "no similarity warning printed"
  assert_not_contains "$out" "already carries" "title similarity produced a refusal message"
  [ -f "$HOME_DIR/state/$NEW_ID.meta" ] || fail "a similarity warning must not stop the spawn"
  pass "base commits, distinct commits, landed commits, closed tasks, and non-commit hex stay allowed"
}

# 5. Concurrent attempts and retries.
test_concurrent_spawns_and_retries_create_one_owner() {
  local round x out_a out_b rc_a rc_b pid_a pid_b pane_a pane_b loser_out ok launched failbin relaunchbin status out pane
  for round in 1 2 3; do
    make_case "race-$round"
    x=$(floating_commit "floating race $round")
    fm_test_spawn_brief "$HOME_DIR" race-a1 "Land commit ${x:0:8}."
    fm_test_spawn_brief "$HOME_DIR" race-b2 "Land commit ${x:0:8}."
    : > "$CASE_DIR/launch-a.log"
    : > "$CASE_DIR/launch-b.log"
    out_a="$CASE_DIR/out-a.txt"
    out_b="$CASE_DIR/out-b.txt"
    # Both panes exist before either spawn starts, so a fixture failure cannot
    # masquerade as the lock or the check refusing one of them.
    pane_a=$(add_pane race-a1)
    pane_b=$(add_pane race-b2)
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch-a.log" fm_test_run_spawn "$HOME_DIR" "$pane_a" "$FAKEBIN" \
      race-a1 "$PROJ_DIR" --mode no-mistakes --yolo off > "$out_a" &
    pid_a=$!
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch-b.log" fm_test_run_spawn "$HOME_DIR" "$pane_b" "$FAKEBIN" \
      race-b2 "$PROJ_DIR" --mode no-mistakes --yolo off > "$out_b" &
    pid_b=$!
    rc_a=0
    rc_b=0
    wait "$pid_a" || rc_a=$?
    wait "$pid_b" || rc_b=$?
    ok=0
    [ "$rc_a" -ne 0 ] || ok=$((ok + 1))
    [ "$rc_b" -ne 0 ] || ok=$((ok + 1))
    assert_equals 1 "$ok" "round $round: exactly one of two concurrent spawns must succeed (a=$rc_a b=$rc_b)"
    # The loser is refused by the task-set lock or by the claim, nothing else.
    if [ "$rc_a" -ne 0 ]; then loser_out=$(cat "$out_a"); else loser_out=$(cat "$out_b"); fi
    case "$loser_out" in
      *"task set is locked"*|*"already carries commit"*) : ;;
      *) fail "round $round: the losing spawn failed for another reason: $loser_out" ;;
    esac
    assert_equals 1 "$(claim_holders "$x")" "round $round: exactly one task may own the commit"
    launched=0
    [ ! -s "$CASE_DIR/launch-a.log" ] || launched=$((launched + 1))
    [ ! -s "$CASE_DIR/launch-b.log" ] || launched=$((launched + 1))
    assert_equals 1 "$launched" "round $round: exactly one worker may be launched"
    assert_equals 1 "$(task_records)" "round $round: exactly one task record may exist"
  done

  # A retry of the same task id after a failed launch is not refused by its own
  # earlier attempt and leaves exactly one claim and one launch.
  make_case retry
  x=$(floating_commit "floating retry")
  fm_test_spawn_brief "$HOME_DIR" "$OLD_ID" "Land commit ${x:0:8}."
  failbin="$CASE_DIR/failbin"
  mkdir -p "$failbin"
  cp "$FAKEBIN"/* "$failbin"/
  mv "$failbin/tmux" "$failbin/tmux.real"
  cat > "$failbin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ] && [ -n "\${FM_TEST_FAIL_SEND:-}" ]; then exit 1; fi
exec "$failbin/tmux.real" "\$@"
SH
  chmod +x "$failbin/tmux"
  pane=$(add_pane "$OLD_ID")
  out=$(FM_TEST_FAIL_SEND=1 fm_test_run_spawn "$HOME_DIR" "$pane" "$failbin" "$OLD_ID" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the failed-launch fixture did not fail: $out"
  assert_equals 0 "$(claim_holders "$x")" "a failed launch must not leave a claim behind"
  out=$(spawn_task "$OLD_ID")
  status=$?
  expect_code 0 "$status" "the retry of the same task id must not be refused by its own attempt: $out"
  assert_not_contains "$out" "already carries" "the retry collided with itself"
  assert_equals 1 "$(claim_holders "$x")" "the retry must leave exactly one claim"
  assert_equals 1 "$(grep -c '^commits=' "$HOME_DIR/state/$OLD_ID.meta")" "the retry wrote a second claim line"
  [ -s "$LAUNCH_LOG" ] || fail "the retry did not launch its worker"
  assert_equals 1 "$(task_records)" "the retry left more than one task record"

  # A relaunch republishes the same task: it neither collides nor re-claims.
  # The endpoint reads as an idle shell, so the relaunch has an agent to replace.
  relaunchbin="$CASE_DIR/relaunchbin"
  mkdir -p "$relaunchbin"
  cp "$FAKEBIN"/* "$relaunchbin"/
  cat > "$relaunchbin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-%s\n' "$FM_TEST_RELAUNCH_ID"; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) echo zsh; exit 0 ;;
        *pane_current_path*) echo "$FM_FAKE_PANE_PATH"; exit 0 ;;
      esac
    done
    echo firstmate; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$relaunchbin/tmux"
  out=$(FM_TEST_RELAUNCH_ID="$OLD_ID" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$pane" "$relaunchbin" "$OLD_ID" --relaunch)
  status=$?
  expect_code 0 "$status" "a relaunch of the owning task must not be refused: $out"
  assert_equals 1 "$(claim_holders "$x")" "the relaunch changed the claim holders"
  assert_equals "$x" "$(claim_of "$OLD_ID")" "the relaunch lost or duplicated the claim"
  assert_equals 1 "$(grep -c '^commits=' "$HOME_DIR/state/$OLD_ID.meta")" "the relaunch wrote a second claim line"

  # Promotion of the same task id is not refused by its own claim, and the
  # promoted task then holds the one claim a later spawn collides with.
  make_case promote-self
  x=$(floating_commit "floating promote self")
  add_scout scout-e7 "Ship commit ${x:0:8}."
  out=$(promote_scout scout-e7)
  status=$?
  expect_code 0 "$status" "promotion with no other holder must proceed: $out"
  assert_equals 1 "$(grep -c '^commits=' "$HOME_DIR/state/scout-e7.meta")" "promotion wrote a second claim line"
  out=$(promote_scout scout-e7)
  status=$?
  assert_not_contains "$out" "already carries" "a repeated promotion collided with its own claim"
  assert_equals 1 "$(claim_holders "$x")" "a repeated promotion changed the claim holders"
  write_new_brief "Rework commit ${x:0:8}."
  out=$(spawn_new)
  status=$?
  expect_code 1 "$status" "a later spawn must collide with the promoted task"
  assert_contains "$out" "scout-e7 already carries commit" "refusal does not name the promoted task"
  assert_not_launched "task after promotion"
  pass "concurrent spawns, retries, relaunch, and promotion of one id leave one owner and one worker"
}

# Promotion and spawn publish under one home-wide lock, so neither can pass its
# check while the other is between its own check and its record.
test_task_set_lock_serializes_promotion_and_spawn() {
  local x out status holder promoter outfile
  make_case locked
  x=$(floating_commit "floating locked")
  add_scout scout-e8 "Ship commit ${x:0:8}."
  write_new_brief "Land commit ${x:0:8}."
  bash -c '. "$1"; fm_lock_try_acquire "$2" && exec sleep 60' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR/state/.task-set.lock" &
  holder=$!
  until [ -d "$HOME_DIR/state/.task-set.lock" ]; do sleep 0.1; done

  outfile="$CASE_DIR/promote.out"
  promote_scout scout-e8 > "$outfile" &
  promoter=$!
  sleep 1
  kill -0 "$promoter" 2>/dev/null || fail "a promotion must wait while another operation owns the task set: $(cat "$outfile")"
  assert_grep "kind=scout" "$HOME_DIR/state/scout-e8.meta" "a waiting promotion changed the task kind"
  assert_no_grep "commits=" "$HOME_DIR/state/scout-e8.meta" "a waiting promotion recorded a claim"
  out=$(spawn_new)
  status=$?
  expect_code 1 "$status" "a spawn must refuse while another operation owns the task set"
  assert_not_launched "spawn under a held task-set lock"

  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  wait "$promoter"
  status=$?
  expect_code 0 "$status" "the promotion must proceed once the lock is free: $(cat "$outfile")"
  assert_equals "$x" "$(claim_of scout-e8)" "the promotion did not record its claim"
  assert_absent "$HOME_DIR/state/.task-set.lock" "promotion left the task-set lock behind"
  pass "promotion waits for a locked task set, a spawn refuses, and the lock is released when done"
}

# Gap 5: an unresolvable base must not silently skip the comparison.
test_unresolvable_base_still_compares_recorded_claims() {
  local x out status
  make_case no-base
  x=$(floating_commit "floating no base")
  fm_write_meta "$HOME_DIR/state/$OLD_ID.meta" \
    "window=firstmate:fm-$OLD_ID" "endpoint_task_id=$OLD_ID" "worktree=$CASE_DIR/gone-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "branch=fm/$OLD_ID" "base_branch=release-gone" "commits=$x"
  write_new_brief "Rework commit ${x:0:8}."

  out=$(guard)
  status=$?
  expect_code 1 "$status" "a task whose base ref cannot be resolved must still collide on its claim"
  assert_contains "$out" "$OLD_ID already carries commit" "refusal does not name the holder"

  git -C "$PROJ_DIR" checkout --quiet --detach
  fm_write_meta "$HOME_DIR/state/$OLD_ID.meta" \
    "window=firstmate:fm-$OLD_ID" "endpoint_task_id=$OLD_ID" "worktree=$CASE_DIR/gone-wt" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "branch=fm/$OLD_ID" "commits=$x"
  out=$(guard)
  status=$?
  expect_code 1 "$status" "a detached project with no default ref must still collide on a claim"
  pass "an unresolvable base ref falls back to the recorded claims instead of skipping"
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
test_two_tasks_naming_one_unbranched_commit_are_refused
test_promotion_is_refused_for_a_commit_another_task_holds
test_uppercase_commit_identifiers_are_matched
test_distinct_legitimate_work_stays_allowed
test_concurrent_spawns_and_retries_create_one_owner
test_unresolvable_base_still_compares_recorded_claims
test_task_set_lock_serializes_promotion_and_spawn
