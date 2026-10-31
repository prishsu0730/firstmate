# shellcheck shell=bash
# Durable progress for the away queue's idle episode; lifecycle owners append
# successful starts and landings so short jobs and immediate teardown cannot
# disappear between timer observations. The timer owns interpretation.
# Usage: fm_queue_activity_record <state-dir> <start|landing>
fm_queue_activity_record() {
  local state=$1 event=$2 epoch
  [ -f "$state/.afk-contract" ] || return 0
  case "$event" in start|landing) ;; *) return 2 ;; esac
  [ ! -L "$state/.queue-pull-activity" ] || return 1
  epoch=$(date +%s) || return 1
  printf '%s\t%s\n' "$epoch" "$event" >> "$state/.queue-pull-activity"
}
