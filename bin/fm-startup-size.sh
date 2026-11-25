#!/usr/bin/env bash
# fm-startup-size.sh - print how big a new chat's start-up is, read-only.
#
# Usage: fm-startup-size.sh [--full-open-decisions]
#   Prints one line each for the session-start digest, AGENTS.md, and the total:
#     digest: <bytes> bytes, <words> words
#     AGENTS.md: <bytes> bytes, <words> words
#     total: <bytes> bytes, <words> words
#   --full-open-decisions measures the digest with every open decision listed in
#   full, the shape before the digest kept only a count plus the newest few.
#
# It never takes the session lock and never changes state. The digest is
# produced by bin/fm-session-start.sh with FM_SESSION_START_MEASURE set, which
# runs that script's read-only path and takes the OPEN DECISIONS view from
# bin/fm-wake-drain.sh's read-only listing instead of draining the wake queue.
# The read-only path prints the shorter read-only supervision text, so the digest
# figure is a close lower bound on a locked start, and it is comparable run to run.
# FM_HOME selects the home measured, as for every other bin/ script.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

mode=digest
case "${1:-}" in
  '') ;;
  --full-open-decisions) mode=full ;;
  -h|--help) sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  *) printf 'usage: fm-startup-size.sh [--full-open-decisions]\n' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'usage: fm-startup-size.sh [--full-open-decisions]\n' >&2; exit 2; }

tmp=$(mktemp "${TMPDIR:-/tmp}/fm-startup-size.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
FM_SESSION_START_MEASURE=$mode "$SCRIPT_DIR/fm-session-start.sh" > "$tmp" 2>/dev/null || true

d_bytes=$(LC_ALL=C wc -c < "$tmp" | tr -d '[:space:]')
d_words=$(wc -w < "$tmp" | tr -d '[:space:]')
a_bytes=$(LC_ALL=C wc -c < "$FM_ROOT/AGENTS.md" | tr -d '[:space:]')
a_words=$(wc -w < "$FM_ROOT/AGENTS.md" | tr -d '[:space:]')
printf 'digest: %s bytes, %s words\n' "$d_bytes" "$d_words"
printf 'AGENTS.md: %s bytes, %s words\n' "$a_bytes" "$a_words"
printf 'total: %s bytes, %s words\n' "$((d_bytes + a_bytes))" "$((d_words + a_words))"
