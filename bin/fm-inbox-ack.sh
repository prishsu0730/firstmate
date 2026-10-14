#!/usr/bin/env bash
# fm-inbox-ack.sh - acknowledge steering messages the worker has handled.
#
# Usage:
#   fm-inbox-ack.sh [--inbox <dir>] <id>...
#
# Moves <inbox>/<id>.msg into <inbox>/handled/ and nothing else. <id> is the
# message's numeric sequence (001, or 001.msg). <inbox> defaults to
# "$FM_TASK_INBOX", which bin/fm-spawn.sh exports into every launch; --inbox
# names it explicitly for a worker launched before that export.
#
# It exists so a worker acknowledges a steer with one standalone command
# instead of a bare `mv` with absolute paths, which a global `Bash(mv * /*)`
# ask rule stops on at every message (an ask match beats any allow rule).
#
# Safety: the inbox must be an existing real directory named `<task>.inbox`
# whose handled/ is also a real directory; ids are digits only; the message
# must be a regular file, not a symlink. Anything else is refused with exit 2
# and nothing moves. A message already in handled/ is a quiet success, so a
# re-run is safe. A message found nowhere is exit 1.
set -u

die() { printf 'fm-inbox-ack: %s\n' "$*" >&2; exit 2; }

task_inbox=${FM_TASK_INBOX:-}
inbox=$task_inbox
specified_inbox=
case "${1:-}" in
  --inbox)
    [ $# -ge 2 ] || die "--inbox needs a directory"
    inbox=$2
    specified_inbox=$2
    shift 2
    ;;
  -h|--help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
[ $# -ge 1 ] || die "usage: fm-inbox-ack.sh [--inbox <dir>] <id>..."
[ -n "$inbox" ] || die "no inbox: set FM_TASK_INBOX or pass --inbox <dir>"

resolve_dir() {
  cd -P -- "$1" 2>/dev/null && pwd -P
}

if [ -n "$task_inbox" ] && [ -n "$specified_inbox" ]; then
  task_inbox_resolved=$(resolve_dir "$task_inbox") \
    || die "refusing $task_inbox: cannot resolve FM_TASK_INBOX"
  specified_inbox_resolved=$(resolve_dir "$specified_inbox") \
    || die "refusing $specified_inbox: cannot resolve --inbox"
  [ "$task_inbox_resolved" = "$specified_inbox_resolved" ] \
    || die "refusing $specified_inbox: must match FM_TASK_INBOX"
fi

inbox=${inbox%/}
case "${inbox##*/}" in
  ?*.inbox) ;;
  *) die "refusing $inbox: not a <task>.inbox directory" ;;
esac
[ -d "$inbox" ] && [ ! -L "$inbox" ] || die "refusing $inbox: not a real directory"
[ -d "$inbox/handled" ] && [ ! -L "$inbox/handled" ] \
  || die "refusing $inbox/handled: missing or not a real directory"

rc=0
for raw in "$@"; do
  id=${raw%.msg}
  case "$id" in
    ''|*[!0-9]*) die "refusing '$raw': a message id is digits only, like 001" ;;
  esac
  src="$inbox/$id.msg"
  dst="$inbox/handled/$id.msg"
  if [ -L "$src" ]; then
    die "refusing $src: a symlink"
  elif [ -f "$src" ]; then
    [ ! -e "$dst" ] && [ ! -L "$dst" ] || die "refusing $src: $dst already exists"
    mv -n -- "$src" "$dst" || die "could not move $src"
    printf 'handled: %s\n' "$id"
  elif [ -f "$dst" ] && [ ! -L "$dst" ]; then
    printf 'already handled: %s\n' "$id"
  else
    printf 'fm-inbox-ack: no message %s in %s\n' "$id" "$inbox" >&2
    rc=1
  fi
done
exit "$rc"
