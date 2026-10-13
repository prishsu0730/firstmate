#!/usr/bin/env bash
# lab-brief.sh <id> <intent>: write a brief the same shape tests/fixtures.sh uses.
. /tmp/fm-g4b-lab.env
mkdir -p "$LAB/data/$1"
cat > "$LAB/data/$1/brief.md" <<EOF
# Task
## Captain's intent
$2

## Firstmate spec
Exercise the duplicate-claim behavior in a live lab.
EOF
