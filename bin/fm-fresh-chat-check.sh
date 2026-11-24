#!/usr/bin/env bash
# Fresh-chat alarm: a UserPromptSubmit hook that refuses NEW work once a Claude
# Code chat holds too much context, and tells the operator to start a fresh chat.
#
# It runs only where a new prompt arrives, so it never interrupts a turn that is
# already under way: tool calls, subagents, and a running pipeline are untouched.
#
# Measure: the newest main-thread assistant entry in the session transcript
# (payload field transcript_path) carries a usage block. Context size is
# input_tokens + cache_read_input_tokens + cache_creation_input_tokens of that
# entry, which is what the model read on its last step.
#
# Limit: tokens, default 150000. First non-empty source wins:
#   1. FM_FRESH_CHAT_LIMIT env var
#   2. first line of config/fresh-chat-limit (under FM_CONFIG_OVERRIDE or FM_HOME)
#   3. the default 150000
# The value 0 or "off" disables the alarm. An invalid value uses the default.
# docs/configuration.md owns the documented contract.
#
# Scope: a genuine primary home only (fm-primary-scope-lib.sh). A crewmate or
# scout task worktree is inert, because steering messages reach it as prompts and
# must not be refused mid-task.
#
# Output contract:
#   ALLOW - exit 0, no output.
#   BLOCK - exit 0 and {"decision":"block","reason":"... start a fresh chat ..."}
#           on stdout. Claude Code erases the prompt and shows the reason.
#   Prompts that start with "/" (for example /compact, /clear) always pass, so
#   the operator can still shrink or leave the chat.
#   Unmeasurable context (no transcript, no usage entry, no jq) steps aside: the
#   prompt is allowed, and a systemMessage says so once per session.
#   Foreign hosts (Cursor payloads) and malformed payloads allow silently.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
DEFAULT_LIMIT=150000

case "${1-}" in
  -h|--help)
    echo "Usage: <UserPromptSubmit JSON on stdin> | fm-fresh-chat-check.sh"
    echo "Blocks a new prompt when chat context passes the limit (default $DEFAULT_LIMIT tokens)."
    exit 0
    ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_root_matches "$FM_ROOT" || exit 0

limit=${FM_FRESH_CHAT_LIMIT:-}
if [ -z "$limit" ] && [ -f "$CONFIG/fresh-chat-limit" ]; then
  IFS= read -r limit < "$CONFIG/fresh-chat-limit" 2>/dev/null || limit=
  limit=${limit//[[:space:]]/}
fi
case "$limit" in
  0|off|OFF|Off) exit 0 ;;
  ''|*[!0-9]*) limit=$DEFAULT_LIMIT ;;
esac

step_aside() {  # <reason>: allow, and say so once per session
  local sid marker
  sid=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null) || sid=
  sid=${sid//[^A-Za-z0-9._-]/}
  marker="$STATE/.fresh-chat-unmeasured-${sid:-unknown}"
  if [ -d "$STATE" ] && [ ! -e "$marker" ]; then
    : > "$marker" 2>/dev/null || exit 0
    printf '{"systemMessage":"Fresh-chat alarm is off for this chat: %s."}\n' "$1"
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

prompt=$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null) || prompt=
case "$prompt" in
  /*) exit 0 ;;
esac

transcript=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || transcript=
[ -n "$transcript" ] && [ -f "$transcript" ] || step_aside "the chat log was not found, so its size cannot be measured"

command -v perl >/dev/null 2>&1 || step_aside "the chat log reader is unavailable, so its size cannot be measured"
used=$(perl -e '
  my $path = shift;
  open my $fh, "<", $path or exit 1;
  binmode $fh;
  seek($fh, 0, 2) or exit 1;
  my $pos = tell($fh);
  my $partial = "";
  while ($pos > 0) {
    my $size = $pos > 65536 ? 65536 : $pos;
    $pos -= $size;
    seek($fh, $pos, 0) or exit 1;
    read($fh, my $chunk, $size) == $size or exit 1;
    my @lines = split /\n/, $chunk . $partial, -1;
    $partial = shift @lines;
    for my $line (reverse @lines) { print "$line\n" }
  }
  print "$partial\n" if length $partial;
' "$transcript" | jq -R -r '
  fromjson? |
  if .type == "assistant" and (.isSidechain | not) then
    (if (.message.usage? | type) == "object" then
      ((.message.usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0))
    else "no-usage" end),
    halt
  else empty end' 2>/dev/null)
if [ "$used" = no-usage ]; then exit 0; fi
case "$used" in
  ''|*[!0-9]*) step_aside "the chat log has no token count yet, so its size cannot be measured" ;;
esac

[ "$used" -gt "$limit" ] || exit 0
printf '{"decision":"block","reason":"This chat holds about %s tokens of context, past the %s limit. Please start a fresh chat for new work. Work already under way keeps running."}\n' "$used" "$limit"
exit 0
