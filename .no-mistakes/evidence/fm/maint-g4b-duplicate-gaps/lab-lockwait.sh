#!/usr/bin/env bash
# Live lock check: another operation holds the home's task-set lock; a real
# promotion must wait (not refuse), a real spawn must refuse, and the promotion
# must finish once the lock frees.
E=/Users/priscillahsu/.no-mistakes/evidence/01M4T5F4EWZSZJBYY5C4BVQ4NH
WT=/Users/priscillahsu/.no-mistakes/worktrees/d3979e0d8bb7/01M4T5F4EWZSZJBYY5C4BVQ4NH
. /tmp/fm-g4b-lab.env
cd "$WT"
bash -c '. "$1"; fm_lock_try_acquire "$2" && exec sleep 120' _ bin/fm-wake-lib.sh "$LAB/state/.task-set.lock" &
holder=$!
until [ -d "$LAB/state/.task-set.lock" ]; do sleep 0.1; done
echo "held task-set lock (pid $holder)"
bin/fm-promote.sh labsc6 --mode no-mistakes --yolo off > "$LAB/out/lock-promote.txt" 2>&1 &
promoter=$!
sleep 3
if kill -0 "$promoter" 2>/dev/null; then echo "after 3s: promotion still WAITING (alive)"; else echo "after 3s: promotion EXITED: $(cat "$LAB/out/lock-promote.txt")"; fi
echo "labsc6 meta while waiting: $(grep -E '^kind=' "$LAB/state/labsc6.meta")"
echo "--- spawn while lock held:"
bin/fm-spawn.sh labff6 "$LAB/projects/demo" --mode no-mistakes --yolo off 2>&1; echo "spawn exit=$?"
[ -e "$LAB/state/labff6.meta" ] && echo "labff6.meta EXISTS" || echo "labff6.meta absent"
kill "$holder"; wait "$holder" 2>/dev/null
echo "released lock"
wait "$promoter"; echo "promotion exit=$?"
cat "$LAB/out/lock-promote.txt"
grep -E '^(kind|commits)=' "$LAB/state/labsc6.meta"
[ -e "$LAB/state/.task-set.lock" ] && echo "lock LEFT BEHIND" || echo "lock released after promotion"
