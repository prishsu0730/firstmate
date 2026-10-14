#!/usr/bin/env bash
# Drives bin/fm-inbox-ack.sh against throwaway sibling inboxes A and B.
# Usage: drive-inbox-ack.sh <path-to-fm-inbox-ack.sh> <scratch-dir>
ACK=$1; T=$2
show() { (cd "$T" && find state -name '*.msg' | sort); }
mkdir -p "$T/state/A.inbox/handled" "$T/state/B.inbox/handled"
echo steerA > "$T/state/A.inbox/001.msg"; echo steerB > "$T/state/B.inbox/001.msg"
echo "== S1 bound to A, stale --inbox B 001 (must refuse, exit 2, nothing moves)"
FM_TASK_INBOX="$T/state/A.inbox" "$ACK" --inbox "$T/state/B.inbox" 001; echo "exit=$?"; show
echo "== S2 bound to A, --inbox A spelled differently (B.inbox/../A.inbox/) 001 (must succeed)"
FM_TASK_INBOX="$T/state/A.inbox" "$ACK" --inbox "$T/state/B.inbox/../A.inbox/" 001; echo "exit=$?"; show
echo "== S3 bound to A, --inbox is a symlink alias of A (later no-symlink guard must still refuse)"
ln -s "$T/state/A.inbox" "$T/alias.inbox"; echo s2 > "$T/state/A.inbox/002.msg"
FM_TASK_INBOX="$T/state/A.inbox" "$ACK" --inbox "$T/alias.inbox" 002; echo "exit=$?"; show
echo "== S4 bound to A, --inbox points at a missing C.inbox (must refuse, exit 2)"
FM_TASK_INBOX="$T/state/A.inbox" "$ACK" --inbox "$T/state/C.inbox" 002; echo "exit=$?"
echo "== S5 no FM_TASK_INBOX (worker launched before the export), --inbox B 001 (fallback must work)"
env -u FM_TASK_INBOX "$ACK" --inbox "$T/state/B.inbox" 001; echo "exit=$?"; show
echo "== S6 env only (doorbell form), FM_TASK_INBOX=A 002 (must succeed)"
FM_TASK_INBOX="$T/state/A.inbox" "$ACK" 002; echo "exit=$?"; show
