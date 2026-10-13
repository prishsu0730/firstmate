#!/usr/bin/env bash
# lab-run.sh <step-name> <cmd...>: type one lab-step into the lab primary pane, wait, print result.
E=/Users/priscillahsu/.no-mistakes/evidence/01M4T5F4EWZSZJBYY5C4BVQ4NH
. /tmp/fm-g4b-lab.env
export TMUX_TMPDIR=$LAB/tmux
name=$1; shift
tmux -L fm-lab send-keys -t primary:0 "bash $E/lab-step.sh $name $*" Enter
for _ in $(seq 1 90); do
  tmux -L fm-lab capture-pane -p -t primary:0 -S -200 | grep -q "DONE $name" && break
  sleep 2
done
cat "$LAB/out/$name.txt"
