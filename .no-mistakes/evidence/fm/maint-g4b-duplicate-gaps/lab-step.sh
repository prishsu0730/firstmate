#!/usr/bin/env bash
# Run inside the lab primary pane: lab-step.sh <name> <cmd...>
# Records the command, its combined output, and its exit code to $LAB/out/<name>.txt
. /tmp/fm-g4b-lab.env
name=$1; shift
WT=/Users/priscillahsu/.no-mistakes/worktrees/d3979e0d8bb7/01M4T5F4EWZSZJBYY5C4BVQ4NH
cd "$WT"
{
  echo "\$ $*"
  "$@" 2>&1
  echo "exit=$?"
} > "$LAB/out/$name.txt" 2>&1
echo "DONE $name"
