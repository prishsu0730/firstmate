#!/usr/bin/env bash
# Tests for bin/fm-file-boundary.sh: the per-ticket file boundary. A task may
# carry an allowed-file list; the checker compares the files a branch or live
# pull request changes with it, and a task with no list is never touched.
#
# The cases drive the checker through its public entrypoint against real git
# repositories and a faked `gh`, and end with the exact command a ship brief
# scaffolded with --allowed-files hands its worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CHECKER="$ROOT/bin/fm-file-boundary.sh"
BRIEF_SCRIPT="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-file-boundary)
command -v jq >/dev/null 2>&1 || fail "these tests read the faked gh's JSON with jq, which was not found"

TASK=task-b1
PR_URL=https://github.com/example/repo/pull/9
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# make_case <name>: a fresh home with task metadata, a git worktree on branch
# fm/task-b1 whose origin/main is the initial commit, and a fakebin directory.
# Echoes the case directory.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/data" "$case_dir/home/config" "$case_dir/state" "$case_dir/fakebin" "$case_dir/elsewhere"
  fm_git_init_commit "$case_dir/wt"
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  git -C "$case_dir/wt" checkout -q -b "fm/$TASK"
  fm_write_meta "$case_dir/state/$TASK.meta" \
    "window=fm-$TASK" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# commit_files <case_dir> <path>...: commit a change to each path on the branch.
commit_files() {
  local case_dir=$1 path
  shift
  for path in "$@"; do
    mkdir -p "$case_dir/wt/$(dirname "$path")"
    printf 'change\n' >> "$case_dir/wt/$path"
    git -C "$case_dir/wt" add -- "$path"
  done
  git -C "$case_dir/wt" -c user.name=t -c user.email=t@example.invalid commit -qm "change $*"
}

# write_list <case_dir> <line>...: record the task's allowed-file list.
write_list() {
  local case_dir=$1
  shift
  mkdir -p "$case_dir/home/data/$TASK"
  printf '%s\n' "$@" > "$case_dir/home/data/$TASK/allowed-files"
}

# gh mock: the PR head and the pull request's file list, as the forge reports
# them. Marker files in the case dir drive the failure modes.
add_gh_mock() {
  local case_dir=$1
  printf '%s\n' "$HEAD_SHA" > "$case_dir/pr-head"
  printf '[]\n' > "$case_dir/pr-files.json"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CASE/gh.log"
[ ! -e "$FM_TEST_CASE/gh-fails" ] || exit 1
case "${1:-} ${2:-}" in
  "pr view")
    cat "$FM_TEST_CASE/pr-head"
    exit 0
    ;;
  "api --paginate")
    expr=
    prev=
    for arg in "$@"; do
      [ "$prev" = --jq ] && expr=$arg
      prev=$arg
    done
    case " $* " in
      *" repos/example/repo/pulls/9/files "*) jq -r "${expr:-.}" "$FM_TEST_CASE/pr-files.json" ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
}

# write_pr_files <case_dir> <path>...: the live pull request's changed files.
# A "new>old" argument is a rename, which the forge reports with the old path.
write_pr_files() {
  local case_dir=$1 entry out='' sep=''
  shift
  for entry in "$@"; do
    case "$entry" in
      *'>'*) out="$out$sep{\"filename\":\"${entry%%>*}\",\"previous_filename\":\"${entry#*>}\"}" ;;
      *) out="$out$sep{\"filename\":\"$entry\"}" ;;
    esac
    sep=,
  done
  printf '[%s]\n' "$out" > "$case_dir/pr-files.json"
}

# run_checker <case_dir> <args>...: run the checker from outside the worktree so
# the worktree is found through task metadata. Sets RC, OUT, ERR.
run_checker() {
  local case_dir=$1
  shift
  RC=0
  (
    cd "$case_dir/elsewhere" || exit 99
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_CASE="$case_dir" \
    PATH="$case_dir/fakebin:$PATH" \
      "$CHECKER" "$@"
  ) > "$case_dir/out" 2> "$case_dir/err" || RC=$?
  OUT=$(cat "$case_dir/out")
  ERR=$(cat "$case_dir/err")
}

test_script_parses() {
  local out rc=0
  out=$(bash -n "$CHECKER" 2>&1) || rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-file-boundary.sh must parse cleanly (got: $out)"
  pass "fm-file-boundary.sh: bash -n succeeds"
}

test_help_prints_the_header() {
  local out rc=0
  out=$("$CHECKER" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" 'check <task-id>' "--help did not show the check usage"
  assert_contains "$out" 'recorded <task-id>' "--help did not show the recorded usage"
  pass "fm-file-boundary.sh: --help prints the header"
}

test_in_list_change_passes() {
  local case_dir
  case_dir=$(make_case in-list)
  write_list "$case_dir" bin/fm-brief.sh 'tests/fm-brief*.test.sh'
  commit_files "$case_dir" bin/fm-brief.sh tests/fm-brief.test.sh
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "in-list: a change inside the list must pass"
  assert_contains "$OUT" 'within the allowed list' "in-list: the pass was not stated"
  [ -z "$ERR" ] || fail "in-list: a pass wrote to stderr: $ERR"
  pass "fm-file-boundary check passes when every changed file is in the list"
}

test_extra_file_fails_and_is_named() {
  local case_dir
  case_dir=$(make_case extra-file)
  write_list "$case_dir" bin/fm-brief.sh
  commit_files "$case_dir" bin/fm-brief.sh bin/fm-spawn.sh docs/notes.md
  run_checker "$case_dir" check "$TASK"
  expect_code 1 "$RC" "extra-file: a file outside the list must fail"
  assert_contains "$ERR" 'bin/fm-spawn.sh' "extra-file: the first extra file was not named"
  assert_contains "$ERR" 'docs/notes.md' "extra-file: the second extra file was not named"
  assert_not_contains "$ERR" '  - bin/fm-brief.sh' "extra-file: an in-list file was named as a violation"
  pass "fm-file-boundary check exits 1 and names every file outside the list"
}

test_no_list_passes_with_a_note() {
  local case_dir
  case_dir=$(make_case no-list)
  commit_files "$case_dir" anything/at/all.txt
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "no-list: a task with no list must pass"
  assert_contains "$OUT" 'no boundary recorded' "no-list: the note was not printed"
  assert_absent "$case_dir/home/data/$TASK" "no-list: the checker created task data"
  run_checker "$case_dir" recorded "$TASK"
  expect_code 1 "$RC" "no-list: recorded must exit 1"
  [ -z "$OUT$ERR" ] || fail "no-list: recorded must be silent (got: $OUT$ERR)"
  pass "fm-file-boundary check passes with a note, and recorded is silent, when no list exists"
}

test_recorded_names_the_list() {
  local case_dir
  case_dir=$(make_case recorded)
  write_list "$case_dir" bin/a.sh
  run_checker "$case_dir" recorded "$TASK"
  expect_code 0 "$RC" "recorded: a recorded list must exit 0"
  assert_equals "$case_dir/home/data/$TASK/allowed-files" "$OUT" "recorded: wrong list path"
  pass "fm-file-boundary recorded prints the list path when one exists"
}

test_glob_matching_stays_inside_a_directory() {
  local case_dir
  case_dir=$(make_case glob)
  write_list "$case_dir" 'bin/*.sh' 'docs/**' 'tests/fm-?.test.sh' 'README.md'
  commit_files "$case_dir" bin/a.sh docs/deep/nested/page.md docs/top.md tests/fm-x.test.sh README.md
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "glob: matching files must pass (stderr: $ERR)"

  commit_files "$case_dir" bin/sub/b.sh
  run_checker "$case_dir" check "$TASK"
  expect_code 1 "$RC" "glob: * must not cross a directory"
  assert_contains "$ERR" 'bin/sub/b.sh' "glob: the nested file was not named"

  git -C "$case_dir/wt" reset -q --hard HEAD~1
  commit_files "$case_dir" tests/fm-xy.test.sh
  run_checker "$case_dir" check "$TASK"
  expect_code 1 "$RC" "glob: ? must match exactly one character"
  assert_contains "$ERR" 'tests/fm-xy.test.sh' "glob: the two-character name was not named"
  pass "fm-file-boundary glob entries match, and * and ? stay inside one directory"
}

test_globstar_matches_zero_directories() {
  local case_dir
  case_dir=$(make_case globstar)
  write_list "$case_dir" 'docs/**/*.md' '**/*.sh' 'src/**/x/*.c' 'app/[id]/page.tsx'
  commit_files "$case_dir" docs/a.md docs/one/two/b.md a.sh deep/er/c.sh src/x/d.c src/m/n/x/e.c 'app/[id]/page.tsx'
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "globstar: **/ must match zero or more directories, and [ is literal (stderr: $ERR)"

  commit_files "$case_dir" src/a/x/b/c.c docs/a.txt app/i/page.tsx
  run_checker "$case_dir" check "$TASK"
  expect_code 1 "$RC" "globstar: * after ** must still stay inside one directory"
  assert_contains "$ERR" 'src/a/x/b/c.c' "globstar: the file under x/b/ was not named"
  assert_contains "$ERR" 'docs/a.txt' "globstar: the non-matching extension was not named"
  assert_contains "$ERR" 'app/i/page.tsx' "globstar: [id] must not match as a character class"
  assert_not_contains "$ERR" '  - docs/a.md' "globstar: an in-list file was named"
  pass "fm-file-boundary **/ matches zero or more directories, while * and ? stay inside one"
}

test_non_ascii_path_matches_its_entry() {
  local case_dir
  case_dir=$(make_case non-ascii)
  write_list "$case_dir" 'docs/café.md' 'docs/a"b.md'
  commit_files "$case_dir" 'docs/café.md' 'docs/a"b.md'
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "non-ascii: non-ASCII and double-quote files in the list must pass (got: $ERR)"
  commit_files "$case_dir" 'docs/naïve.md'
  run_checker "$case_dir" check "$TASK"
  expect_code 1 "$RC" "non-ascii: a non-ASCII file outside the list must fail"
  assert_contains "$ERR" 'docs/naïve.md' "non-ascii: the extra file was not named as written"
  pass "fm-file-boundary check compares non-ASCII and quote-holding paths as written, not git-quoted"
}

test_rename_and_delete_count_both_paths() {
  local case_dir
  case_dir=$(make_case rename)
  mkdir -p "$case_dir/wt/keep" "$case_dir/wt/other"
  printf 'x\n' > "$case_dir/wt/keep/in.txt"
  printf 'x\n' > "$case_dir/wt/other/out.txt"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" -c user.name=t -c user.email=t@example.invalid commit -qm seed
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main HEAD
  write_list "$case_dir" 'keep/*' 'moved/*'

  mkdir -p "$case_dir/wt/moved"
  git -C "$case_dir/wt" mv keep/in.txt moved/in.txt
  git -C "$case_dir/wt" -c user.name=t -c user.email=t@example.invalid commit -qm "rename inside the list"
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "rename: a rename between in-list paths must pass (stderr: $ERR)"

  git -C "$case_dir/wt" rm -q other/out.txt
  git -C "$case_dir/wt" -c user.name=t -c user.email=t@example.invalid commit -qm "delete outside the list"
  run_checker "$case_dir" check "$TASK"
  expect_code 1 "$RC" "rename: deleting a file outside the list must fail"
  assert_contains "$ERR" 'other/out.txt' "rename: the deleted file was not named"
  pass "fm-file-boundary counts renames and deletions against both paths"
}

test_base_branch_comes_from_task_metadata() {
  local case_dir
  case_dir=$(make_case base-branch)
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  commit_files "$case_dir" release/base-work.txt
  git -C "$case_dir/wt" update-ref refs/remotes/origin/release "$(git -C "$case_dir/wt" rev-parse HEAD)"
  commit_files "$case_dir" mine/change.txt
  write_list "$case_dir" 'mine/*'
  printf 'base_branch=release\n' >> "$case_dir/state/$TASK.meta"
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "base-branch: only the work since origin/release counts (stderr: $ERR)"
  pass "fm-file-boundary measures from the task's recorded base branch"
}

test_unresolvable_base_fails_closed() {
  local case_dir
  case_dir=$(make_case no-base)
  write_list "$case_dir" bin/a.sh
  git -C "$case_dir/wt" update-ref -d refs/remotes/origin/main
  run_checker "$case_dir" check "$TASK"
  expect_code 2 "$RC" "no-base: an unreadable base must not pass"
  assert_contains "$ERR" 'base' "no-base: the refusal did not say what was missing"
  pass "fm-file-boundary fails closed when it cannot find the base to compare against"
}

test_task_id_and_usage_errors() {
  local case_dir
  case_dir=$(make_case usage)
  run_checker "$case_dir" check '../escape'
  expect_code 2 "$RC" "usage: a path-like task id must be refused"
  run_checker "$case_dir" check
  expect_code 2 "$RC" "usage: a missing task id must be refused"
  run_checker "$case_dir" frobnicate "$TASK"
  expect_code 2 "$RC" "usage: an unknown subcommand must be refused"
  run_checker "$case_dir" check "$TASK" --head "$HEAD_SHA"
  expect_code 2 "$RC" "usage: --head without --pr must be refused"
  run_checker "$case_dir" check "$TASK" --pr not-a-url
  expect_code 2 "$RC" "usage: a malformed PR URL must be refused"
  pass "fm-file-boundary refuses malformed invocations with exit 2"
}

test_pr_files_in_list_pass() {
  local case_dir
  case_dir=$(make_case pr-pass)
  add_gh_mock "$case_dir"
  write_list "$case_dir" bin/fm-brief.sh 'tests/*.test.sh'
  write_pr_files "$case_dir" bin/fm-brief.sh tests/fm-brief.test.sh
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL"
  expect_code 0 "$RC" "pr-pass: in-list PR files must pass (stderr: $ERR)"
  assert_contains "$OUT" 'within the allowed list' "pr-pass: the pass was not stated"
  pass "fm-file-boundary check --pr passes when the live PR file list is in the list"
}

test_pr_extra_file_fails_and_is_named() {
  local case_dir
  case_dir=$(make_case pr-extra)
  add_gh_mock "$case_dir"
  write_list "$case_dir" bin/fm-brief.sh
  write_pr_files "$case_dir" bin/fm-brief.sh bin/fm-spawn.sh
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL"
  expect_code 1 "$RC" "pr-extra: a PR file outside the list must fail"
  assert_contains "$ERR" 'bin/fm-spawn.sh' "pr-extra: the extra file was not named"
  pass "fm-file-boundary check --pr exits 1 and names a live PR file outside the list"
}

test_pr_rename_counts_the_old_path() {
  local case_dir
  case_dir=$(make_case pr-rename)
  add_gh_mock "$case_dir"
  write_list "$case_dir" 'new/*'
  write_pr_files "$case_dir" 'new/file.txt>old/file.txt'
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL"
  expect_code 1 "$RC" "pr-rename: the path a rename leaves must count"
  assert_contains "$ERR" 'old/file.txt' "pr-rename: the old path was not named"
  pass "fm-file-boundary check --pr counts a rename's previous path"
}

test_pr_head_binding() {
  local case_dir
  case_dir=$(make_case pr-head)
  add_gh_mock "$case_dir"
  write_list "$case_dir" bin/a.sh
  write_pr_files "$case_dir" bin/a.sh
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL" --head "$HEAD_SHA"
  expect_code 0 "$RC" "pr-head: a matching head must pass (stderr: $ERR)"
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL" --head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  expect_code 2 "$RC" "pr-head: a head that moved must fail as an unmade check"
  assert_contains "$ERR" "$HEAD_SHA" "pr-head: the live head was not named"
  pass "fm-file-boundary check --pr --head refuses a head that moved since it was verified"
}

test_pr_unreadable_fails_closed() {
  local case_dir
  case_dir=$(make_case pr-unreadable)
  add_gh_mock "$case_dir"
  write_list "$case_dir" bin/a.sh
  : > "$case_dir/gh-fails"
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL"
  expect_code 2 "$RC" "pr-unreadable: an unreadable file list must not pass"
  pass "fm-file-boundary check --pr fails closed when the forge file list cannot be read"
}

test_pr_without_list_never_calls_the_forge() {
  local case_dir
  case_dir=$(make_case pr-no-list)
  add_gh_mock "$case_dir"
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL"
  expect_code 0 "$RC" "pr-no-list: no list must pass"
  assert_contains "$OUT" 'no boundary recorded' "pr-no-list: the note was not printed"
  assert_absent "$case_dir/gh.log" "pr-no-list: the forge was called for a task with no list"
  pass "fm-file-boundary check --pr makes no forge call when no list is recorded"
}

test_pr_on_another_forge_fails_closed() {
  local case_dir
  case_dir=$(make_case pr-gitlab)
  add_gh_mock "$case_dir"
  write_list "$case_dir" bin/a.sh
  run_checker "$case_dir" check "$TASK" --pr https://gitlab.example/group/project/-/merge_requests/7
  expect_code 2 "$RC" "pr-gitlab: a forge the checker cannot read must not pass"
  assert_contains "$ERR" 'gitlab' "pr-gitlab: the refusal did not name the forge"
  pass "fm-file-boundary check --pr fails closed on a forge it cannot read"
}

test_newline_in_a_local_path_never_splits_into_allowed_names() {
  local case_dir
  case_dir=$(make_case newline-local)
  write_list "$case_dir" a b 'my file.txt'
  commit_files "$case_dir" 'my file.txt'
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "newline-local: a name with a space must still pass (stderr: $ERR)"
  printf 'x\n' > "$case_dir/wt/$(printf 'a\nb')"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" -c user.name=t -c user.email=t@example.invalid commit -qm "newline name"
  run_checker "$case_dir" check "$TASK"
  expect_code 1 "$RC" "newline-local: one file named a<newline>b must not read as the allowed names a and b"
  assert_contains "$ERR" 'newline' "newline-local: the refusal did not say why"
  pass "fm-file-boundary check does not split a local path containing a newline into allowed names"
}

test_newline_in_a_pr_path_never_splits_into_allowed_names() {
  local case_dir
  case_dir=$(make_case newline-pr)
  add_gh_mock "$case_dir"
  write_list "$case_dir" docs/a b.md
  printf '%s\n' '[{"filename":"docs/a\nb.md"}]' > "$case_dir/pr-files.json"
  run_checker "$case_dir" check "$TASK" --pr "$PR_URL"
  expect_code 1 "$RC" "newline-pr: one file named docs/a<newline>b.md must not read as the allowed names docs/a and b.md"
  assert_contains "$ERR" 'newline' "newline-pr: the refusal did not say why"
  pass "fm-file-boundary check --pr does not split a PR path containing a newline into allowed names"
}

# scaffold_boundary_brief <case_dir>: a real ship brief with a list, so the
# record is the one the scaffold writes.
scaffold_boundary_brief() {
  local case_dir=$1
  printf '%s\n' bin/a.sh > "$case_dir/list.txt"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    "$BRIEF_SCRIPT" "$TASK" some-proj --mode no-mistakes --allowed-files "$case_dir/list.txt" >/dev/null \
    || fail "the brief with a list did not scaffold"
}

test_a_lost_list_fails_closed() {
  local case_dir
  case_dir=$(make_case lost-list)
  scaffold_boundary_brief "$case_dir"
  commit_files "$case_dir" bin/a.sh
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "lost-list: the recorded list must pass an in-list change (stderr: $ERR)"

  rm -f "$case_dir/home/data/$TASK/allowed-files"
  run_checker "$case_dir" check "$TASK"
  expect_code 2 "$RC" "lost-list: a deleted list must not read as no boundary"
  assert_contains "$ERR" 'briefed with an allowed-file list' "lost-list: the refusal did not say what was lost"
  run_checker "$case_dir" recorded "$TASK"
  expect_code 2 "$RC" "lost-list: recorded must say the boundary cannot be read"

  mkdir "$case_dir/home/data/$TASK/allowed-files"
  run_checker "$case_dir" check "$TASK"
  expect_code 2 "$RC" "lost-list: a list replaced by a directory must not read as no boundary"
  pass "fm-file-boundary fails closed when a recorded list has been deleted or replaced"
}

test_an_unreadable_task_directory_fails_closed() {
  local case_dir
  case_dir=$(make_case unreadable-dir)
  scaffold_boundary_brief "$case_dir"
  if [ "$(id -u)" -eq 0 ]; then
    pass "fm-file-boundary unreadable task directory (skipped: running as root)"
    return 0
  fi
  chmod 000 "$case_dir/home/data/$TASK"
  run_checker "$case_dir" check "$TASK"
  chmod 755 "$case_dir/home/data/$TASK"
  expect_code 2 "$RC" "unreadable-dir: a task directory that cannot be read must not read as no boundary"
  pass "fm-file-boundary fails closed when the task directory cannot be read"
}

test_a_task_never_briefed_with_a_list_is_untouched() {
  local case_dir
  case_dir=$(make_case never-briefed)
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    "$BRIEF_SCRIPT" "$TASK" some-proj --mode no-mistakes >/dev/null \
    || fail "the plain brief did not scaffold"
  commit_files "$case_dir" anything/at/all.txt
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "never-briefed: a task with no list must pass (stderr: $ERR)"
  assert_contains "$OUT" 'no boundary recorded' "never-briefed: the note was not printed"
  run_checker "$case_dir" recorded "$TASK"
  expect_code 1 "$RC" "never-briefed: recorded must exit 1"
  pass "fm-file-boundary leaves a task that was never briefed with a list exactly as before"
}

test_a_marker_quoted_outside_the_allowed_files_section_is_no_boundary() {
  local case_dir
  case_dir=$(make_case quoted-marker)
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    "$BRIEF_SCRIPT" "$TASK" some-proj --mode no-mistakes >/dev/null \
    || fail "quoted-marker: the plain brief did not scaffold"
  printf '%s\n' 'The earlier brief said:' 'File boundary: required' '# Allowed files' '' 'File boundary: required' \
    >> "$case_dir/home/data/$TASK/brief.md"
  commit_files "$case_dir" anything/at/all.txt
  run_checker "$case_dir" check "$TASK"
  expect_code 0 "$RC" "quoted-marker: a task with no list must pass (stderr: $ERR)"
  assert_contains "$OUT" 'no boundary recorded' "quoted-marker: the note was not printed"
  run_checker "$case_dir" recorded "$TASK"
  expect_code 1 "$RC" "quoted-marker: recorded must exit 1"
  pass "fm-file-boundary ignores the boundary marker anywhere but right after the Allowed files heading"
}

# The command a brief scaffolded with --allowed-files hands its worker must run
# as printed, from the worker's own worktree, and give the verdict.
test_brief_command_runs_as_printed() {
  local case_dir list brief cmd rc=0 out
  case_dir=$(make_case brief-command)
  list="$case_dir/list.txt"
  printf '%s\n' '# the boundary' '' 'bin/a.sh' > "$list"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    "$BRIEF_SCRIPT" "$TASK" some-proj --mode no-mistakes --allowed-files "$list" >/dev/null \
    || fail "brief-command: the brief did not scaffold"
  brief="$case_dir/home/data/$TASK/brief.md"
  assert_present "$case_dir/home/data/$TASK/allowed-files" "brief-command: the list was not recorded"
  cmd=$(grep -E '^   `FM_HOME=.*fm-file-boundary\.sh.* check ' "$brief" | head -n 1 | sed "s/^   \`//; s/\`\$//")
  [ -n "$cmd" ] || fail "brief-command: the brief carries no runnable checker command"

  commit_files "$case_dir" bin/a.sh
  out=$(cd "$case_dir/wt" && FM_STATE_OVERRIDE="$case_dir/state" bash -c "$cmd" 2>&1) || rc=$?
  expect_code 0 "$rc" "brief-command: the printed command must pass for an in-list change (got: $out)"

  commit_files "$case_dir" bin/extra.sh
  rc=0
  out=$(cd "$case_dir/wt" && FM_STATE_OVERRIDE="$case_dir/state" bash -c "$cmd" 2>&1) || rc=$?
  expect_code 1 "$rc" "brief-command: the printed command must fail for an extra file"
  assert_contains "$out" 'bin/extra.sh' "brief-command: the extra file was not named"
  pass "a brief's printed checker command runs as written and gives the verdict"
}

# When the printed command cannot make the check it exits 2, which the brief
# tells the worker to report with the checker's own error text, not as files.
test_brief_command_unmade_check_exits_2() {
  local case_dir list brief cmd rc=0 out
  case_dir=$(make_case brief-unmade)
  list="$case_dir/list.txt"
  printf '%s\n' 'bin/a.sh' > "$list"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    "$BRIEF_SCRIPT" "$TASK" some-proj --mode no-mistakes --allowed-files "$list" >/dev/null \
    || fail "brief-unmade: the brief did not scaffold"
  brief="$case_dir/home/data/$TASK/brief.md"
  cmd=$(grep -E '^   `FM_HOME=.*fm-file-boundary\.sh.* check ' "$brief" | head -n 1 | sed "s/^   \`//; s/\`\$//")
  [ -n "$cmd" ] || fail "brief-unmade: the brief carries no runnable checker command"
  assert_grep 'Exit 1 means files are outside the list' "$brief" "brief-unmade: exit 1 is not tied to file names"
  assert_grep 'blocked [at=<epoch>]: file boundary check failed: {its error text}' "$brief" \
    "brief-unmade: an unmade check has no blocked line of its own"

  commit_files "$case_dir" bin/a.sh
  git -C "$case_dir/wt" update-ref -d refs/remotes/origin/main
  out=$(cd "$case_dir/wt" && FM_STATE_OVERRIDE="$case_dir/state" bash -c "$cmd" 2>&1) || rc=$?
  expect_code 2 "$rc" "brief-unmade: the printed command must exit 2 when it cannot find the base"
  assert_contains "$out" 'error: cannot find the base branch' "brief-unmade: the error text was not printed"
  pass "a brief's printed checker command exits 2 with its own error when the check cannot be made"
}

test_script_parses
test_help_prints_the_header
test_in_list_change_passes
test_extra_file_fails_and_is_named
test_no_list_passes_with_a_note
test_recorded_names_the_list
test_glob_matching_stays_inside_a_directory
test_globstar_matches_zero_directories
test_non_ascii_path_matches_its_entry
test_rename_and_delete_count_both_paths
test_base_branch_comes_from_task_metadata
test_unresolvable_base_fails_closed
test_task_id_and_usage_errors
test_pr_files_in_list_pass
test_pr_extra_file_fails_and_is_named
test_pr_rename_counts_the_old_path
test_pr_head_binding
test_pr_unreadable_fails_closed
test_pr_without_list_never_calls_the_forge
test_pr_on_another_forge_fails_closed
test_brief_command_runs_as_printed
test_brief_command_unmade_check_exits_2
test_newline_in_a_local_path_never_splits_into_allowed_names
test_newline_in_a_pr_path_never_splits_into_allowed_names
test_a_lost_list_fails_closed
test_an_unreadable_task_directory_fails_closed
test_a_task_never_briefed_with_a_list_is_untouched
test_a_marker_quoted_outside_the_allowed_files_section_is_no_boundary
