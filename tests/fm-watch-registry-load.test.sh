#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$TMP_ROOT/mate/state"
. "$ROOT/bin/fm-watch.sh"
printf -- '- mate - test mate (home: %s; scope: tests; projects: firstmate; added 2026-10-30)\n' \
  "$TMP_ROOT/mate" > "$FM_HOME/data/secondmates.md"
fm_local_firstmate_state_dirs "$STATE"
[ "${#FM_LOCAL_FIRSTMATE_STATES[@]}" -eq 2 ]
[ "${FM_LOCAL_FIRSTMATE_STATES[0]}" = "$STATE" ]
[ "${FM_LOCAL_FIRSTMATE_STATES[1]}" = "$TMP_ROOT/mate/state" ]
printf 'ok - watcher enumerates registered local homes without caller-supplied dependencies\n'
