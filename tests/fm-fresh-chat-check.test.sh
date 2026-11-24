#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the fresh-chat alarm (bin/fm-fresh-chat-check.sh).
# The hook is driven through its real stdin/stdout contract with scratch
# transcripts. No harness is spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-fresh-chat-check)

make_primary() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  cp "$ROOT/bin/fm-fresh-chat-check.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-fresh-chat-check.sh"
}

# write_transcript <file> <cache_read> [input] [cache_creation]
write_transcript() {
  local f=$1 read=$2 in=${3:-2} create=${4:-0}
  {
    printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":9}}}\n' "$in" "$create" "$read"
  } > "$f"
}

payload() {  # <transcript> <prompt> [session]
  jq -n --arg t "$1" --arg p "$2" --arg s "${3:-sess1}" \
    '{session_id:$s,transcript_path:$t,prompt:$p,hook_event_name:"UserPromptSubmit"}'
}

PRIMARY="$TMP_ROOT/primary"
make_primary "$PRIMARY"
CHECK="$PRIMARY/bin/fm-fresh-chat-check.sh"
run_check() {  # <dir> <payload>; stdout in OUT, exit in RC
  OUT=$(printf '%s' "$2" | env -u FM_FRESH_CHAT_LIMIT FM_HOME="$1" "$1/bin/fm-fresh-chat-check.sh" 2>/dev/null)
  RC=$?
}
decision() { printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null; }

test_blocks_new_work_past_limit() {
  write_transcript "$TMP_ROOT/big.jsonl" 160000
  run_check "$PRIMARY" "$(payload "$TMP_ROOT/big.jsonl" 'build the next thing')"
  [ "$RC" -eq 0 ] || fail "block must exit 0, got $RC"
  [ "$(decision)" = "block" ] || fail "expected a block decision, got: $OUT"
  case "$(printf '%s' "$OUT" | jq -r .reason)" in
    *"start a fresh chat"*) ;;
    *) fail "refusal must say 'start a fresh chat': $OUT" ;;
  esac
  pass "chat past 150k gets its next new job refused with the fresh chat line"
}

test_allows_under_limit() {
  write_transcript "$TMP_ROOT/small.jsonl" 100000
  run_check "$PRIMARY" "$(payload "$TMP_ROOT/small.jsonl" 'build the next thing')"
  { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "under the limit must allow silently: rc=$RC out=$OUT"
  pass "chat under the limit is allowed silently"
}

test_sums_cache_and_input_tokens() {
  write_transcript "$TMP_ROOT/sum.jsonl" 100000 20000 31000
  run_check "$PRIMARY" "$(payload "$TMP_ROOT/sum.jsonl" 'go')"
  [ "$(decision)" = "block" ] || fail "151000 summed tokens must block: $OUT"
  pass "context counts input plus cache read plus cache creation"
}

test_ignores_sidechain_usage() {
  write_transcript "$TMP_ROOT/side.jsonl" 100000
  printf '{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":1,"cache_read_input_tokens":900000}}}\n' >> "$TMP_ROOT/side.jsonl"
  run_check "$PRIMARY" "$(payload "$TMP_ROOT/side.jsonl" 'go')"
  [ -z "$OUT" ] || fail "a subagent entry must not count: $OUT"
  pass "subagent entries do not count toward the chat size"
}

test_slash_commands_pass() {
  run_check "$PRIMARY" "$(payload "$TMP_ROOT/big.jsonl" '/compact')"
  [ -z "$OUT" ] || fail "slash commands must pass: $OUT"
  pass "slash commands pass so the chat can still be compacted or cleared"
}

test_limit_from_config_and_env() {
  printf '90000\n' > "$PRIMARY/config/fresh-chat-limit"
  run_check "$PRIMARY" "$(payload "$TMP_ROOT/small.jsonl" 'go')"
  [ "$(decision)" = "block" ] || fail "config limit 90000 must block 100000: $OUT"
  printf 'off\n' > "$PRIMARY/config/fresh-chat-limit"
  run_check "$PRIMARY" "$(payload "$TMP_ROOT/big.jsonl" 'go')"
  [ -z "$OUT" ] || fail "limit off must allow: $OUT"
  : > "$PRIMARY/config/fresh-chat-limit"
  OUT=$(payload "$TMP_ROOT/small.jsonl" go | FM_FRESH_CHAT_LIMIT=50000 FM_HOME="$PRIMARY" "$CHECK" 2>/dev/null)
  [ "$(decision)" = "block" ] || fail "env limit 50000 must block: $OUT"
  pass "the limit is one configurable value: env, then config file, then 150000"
}

test_unmeasurable_steps_aside_once() {
  local p
  p=$(payload "$TMP_ROOT/missing.jsonl" 'go' sessX)
  run_check "$PRIMARY" "$p"
  [ "$RC" -eq 0 ] || fail "unmeasurable must exit 0"
  [ "$(decision)" != "block" ] || fail "unmeasurable must not block: $OUT"
  case "$OUT" in *"cannot be measured"*) ;; *) fail "first unmeasurable prompt must say so: $OUT" ;; esac
  run_check "$PRIMARY" "$p"
  [ -z "$OUT" ] || fail "the notice must appear once per session: $OUT"
  pass "unmeasurable context lets work continue and says so once"
}

test_inert_in_task_worktree() {
  local wt="$TMP_ROOT/wt"
  fm_git_worktree "$PRIMARY" "$wt" fm/fresh-chat-test-branch
  : > "$wt/AGENTS.md"
  mkdir -p "$wt/bin" "$wt/state"
  cp "$PRIMARY"/bin/*.sh "$wt/bin/"
  run_check "$wt" "$(payload "$TMP_ROOT/big.jsonl" 'steer message')"
  [ -z "$OUT" ] || fail "a task worktree must be inert: $OUT"
  pass "crewmate task worktrees are never refused"
}

test_registered_for_claude_prompts() {
  jq -e '.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-fresh-chat-check.sh"))' \
    "$ROOT/.claude/settings.json" >/dev/null || fail "Claude UserPromptSubmit must register the alarm"
  pass "Claude Code registers the alarm on UserPromptSubmit"
}

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  "$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-fresh-chat-check.sh" >/dev/null 2>&1 || fail "bin/fm-fresh-chat-check.sh is not lint-clean"
  pass "bin/fm-fresh-chat-check.sh is clean under bin/fm-lint.sh"
}

test_blocks_new_work_past_limit
test_allows_under_limit
test_sums_cache_and_input_tokens
test_ignores_sidechain_usage
test_slash_commands_pass
test_limit_from_config_and_env
test_unmeasurable_steps_aside_once
test_inert_in_task_worktree
test_registered_for_claude_prompts
test_shellcheck_clean
