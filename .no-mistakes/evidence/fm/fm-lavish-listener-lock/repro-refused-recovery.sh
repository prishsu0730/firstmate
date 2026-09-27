#!/usr/bin/env bash
# Usage: repro-refused-recovery.sh <path-to-fm-watch.sh> <scratch-dir>
# Sets up a dead watcher lock whose recovery mutex cannot be reclaimed
# (mktemp for the reclaim quarantine fails), then starts the watcher.
set -u
WATCH=$1
case_dir=$2
state=$case_dir/state; fakebin=$case_dir/fakebin
mkdir -p "$state" "$fakebin"
real_mktemp=$(command -v mktemp)
cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in *.steal.recovery.reclaim.*) exit 1 ;; esac
exec "$real_mktemp" "\$@"
SH
chmod +x "$fakebin/mktemp"
sleep 0 & dead=$!; wait $dead
mkdir "$state/.watch.lock" "$state/.watch.lock.steal" "$state/.watch.lock.steal.recovery"
for d in .watch.lock .watch.lock.steal .watch.lock.steal.recovery; do echo "$dead" > "$state/$d/pid"; done
touch "$state/.last-watcher-beat"
echo "\$ fm-watch.sh   (lock pid $dead is dead; recovery reclaim refused)"
status=0
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bash "$WATCH" 2>&1 || status=$?
echo "exit status: $status"
if kill -0 "$dead" 2>/dev/null; then echo "pid $dead alive"; else echo "pid $dead is NOT running (no watcher is listening)"; fi
