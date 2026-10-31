#!/usr/bin/env bash
# fm-test-load.sh - wait before heavy browser or simulator work.
# Usage: fm-test-load.sh && <heavy test command>
# Call before starting the command's own timeout; refusal must stop the test.
# Uses Python 3's portable macOS/Linux one-minute load average and CPU count.
# FM_TEST_LOAD_MAX defaults to one runnable task per logical CPU.
# FM_TEST_LOAD_INTERVAL is the positive integer sampling interval (default 30s).
# FM_TEST_LOAD_WAIT is the nonnegative integer wait budget (default 600s).
# Persistent overload exits 1; missing/invalid measurements or settings exit 2.
# A wait is bounded by the budget in sleep seconds, excluding probe overhead.
set -eu
interval=${FM_TEST_LOAD_INTERVAL:-30}
budget=${FM_TEST_LOAD_WAIT:-600}
case "$interval" in ''|*[!0-9]*|0) echo 'invalid FM_TEST_LOAD_INTERVAL' >&2; exit 2 ;; esac
case "$budget" in ''|*[!0-9]*) echo 'invalid FM_TEST_LOAD_WAIT' >&2; exit 2 ;; esac
# Force decimal arithmetic, including values supplied with leading zeroes.
interval=$((10#$interval))
budget=$((10#$budget))
[ "$interval" -gt 0 ] || exit 2
while :; do
  status=0
  python3 - <<'PY' || status=$?
import math
import os
import sys
try:
    limit = float(os.environ.get('FM_TEST_LOAD_MAX', os.cpu_count() or 1))
    load = os.getloadavg()[0]
    if not math.isfinite(limit) or limit <= 0 or not math.isfinite(load) or load < 0:
        raise ValueError('invalid load or threshold')
except (ValueError, OSError) as error:
    print(f'test load probe failed: {error}', file=sys.stderr)
    sys.exit(2)
if load > limit:
    print(f'heavy test waiting: load={load:.2f} limit={limit:g}', file=sys.stderr)
    sys.exit(1)
PY
  case "$status" in
    0) exit 0 ;;
    1) ;;
    *) echo 'cannot measure test machine load' >&2; exit 2 ;;
  esac
  if [ "$budget" -eq 0 ]; then
    echo 'heavy test refused: load remained high for the wait budget' >&2
    exit 1
  fi
  delay=$interval
  [ "$delay" -le "$budget" ] || delay=$budget
  sleep "$delay"
  budget=$((budget - delay))
done
