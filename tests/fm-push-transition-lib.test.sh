#!/usr/bin/env bash
# Delivery-log framing and retention without a watcher or runtime services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records"
# shellcheck source=bin/fm-push-transition-lib.sh
. "$ROOT/bin/fm-push-transition-lib.sh"

# Keep locking local and deterministic without process-identity inspection.
fm_lock_try_acquire() { mkdir "$1"; }
fm_lock_release() { rmdir "$1"; }

test_cleaning() {
  local long cleaned
  [ "$(watch_delivery_clean_identity $'one\ttwo\rthree\nfour')" = 'one two three four' ] || fail 'identity delimiters'
  [ "$(watch_delivery_clean_reason $'signal:\talpha\rnext\nline')" = 'signal: alpha next line' ] || fail 'reason delimiters'
  long=$(printf '%05000d' 0)
  cleaned=$(watch_delivery_clean_reason "$long")
  [ "${#cleaned}" -eq 4096 ] || fail 'reason byte limit'
  [ "$(watch_delivery_clean_identity '')" = '' ] || fail 'empty identity'
  pass 'record delimiters are flattened and reasons are bounded'
}

test_publication() {
  FM_WATCH_DELIVERY_PID=''
  FM_WATCH_DELIVERY_IDENTITY=identity
  watch_delivery_publish ignored || fail 'missing pid return'
  FM_WATCH_DELIVERY_PID=4242
  FM_WATCH_DELIVERY_IDENTITY=''
  watch_delivery_publish ignored || fail 'missing identity return'
  [ ! -e "$WATCH_DELIVERY_LOG" ] || fail 'incomplete identity published'
  FM_WATCH_DELIVERY_IDENTITY=$'started\tat\nnoon'
  watch_delivery_publish $'signal:\talpha\nready' || fail 'publish'
  [ "$(cat "$WATCH_DELIVERY_LOG")" = "$(printf '4242\tstarted at noon\tsignal: alpha ready')" ] || fail 'delivery framing'
  [ ! -e "$WATCH_DELIVERY_LOCK" ] || fail 'lock leaked'
  pass 'only complete identities publish one sanitized tab-separated record'
}

test_retention() {
  local line count
  : > "$WATCH_DELIVERY_LOG"
  WATCH_DELIVERY_MAX_BYTES=80
  WATCH_DELIVERY_KEEP_LINES=2
  FM_WATCH_DELIVERY_IDENTITY=identity
  for count in 1 2 3 4 5; do
    watch_delivery_publish "signal: event-$count" || fail 'bounded publish'
  done
  [ "$(wc -l < "$WATCH_DELIVERY_LOG" | tr -d '[:space:]')" -eq 2 ] || fail 'retained line count'
  [ "$(tail -n 1 "$WATCH_DELIVERY_LOG")" = "$(printf '4242\tidentity\tsignal: event-5')" ] || fail 'newest record retained'
  WATCH_DELIVERY_MAX_BYTES=25
  watch_delivery_publish 'signal: too large to retain as a complete record' || fail 'oversize publish'
  while IFS= read -r line; do
    case "$line" in 4242$'\t'*) ;; *) fail 'partial record retained' ;; esac
  done < "$WATCH_DELIVERY_LOG"
  [ "$(wc -c < "$WATCH_DELIVERY_LOG" | tr -d '[:space:]')" -le 25 ] || fail 'byte retention limit'
  [ ! -e "$WATCH_DELIVERY_LOG.tmp.4242" ] || fail 'temporary file leaked'
  [ ! -e "$WATCH_DELIVERY_LOG.tmp.4242.raw" ] || fail 'raw temporary file leaked'
  [ ! -e "$WATCH_DELIVERY_LOCK" ] || fail 'retention lock leaked'
  pass 'rotation retains newest complete records within line and byte limits'
}

test_cleaning
test_publication
test_retention
