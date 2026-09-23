#!/usr/bin/env bash
# Demo: Lavish arm with leftover broken lock state a real home can hold.
# Usage: demo.sh <repo-root>
set -u
ROOT=$1; T=$(mktemp -d /tmp/fm-demo.XXXX)
mkdir -p "$T/home/state" "$T/claims" "$T/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/lavish-axi"; chmod +x "$T/bin/lavish-axi"
printf '<h1>newest prototype</h1>\n' > "$T/board.html"
run() { PATH="$T/bin:$PATH" FM_HOME="$T/home" FM_PROCEVENT_CLAIM_ROOT="$T/claims" "$ROOT/bin/fm-procevent-lavish.sh" "$@"; }
id=$(run source-id "$T/board.html")
run arm "$T/board.html" >/dev/null || { echo "seed arm failed"; exit 1; }
dead=99999999; while kill -0 $dead 2>/dev/null; do dead=$((dead+1)); done
L="$T/claims/$id.lock"
for d in "$L" "$L.steal" "$L.steal.steal" "$L.steal.recovery"; do mkdir -p "$d"; echo $dead > "$d/pid"; done
echo "== before: leftover lock dirs (all owned by dead pid $dead)"; (cd "$T/claims" && ls -d *.lock* | sed "s/$id/<src>/")
echo "== run: fm-procevent-lavish.sh arm board.html (20s cap)"
start=$SECONDS
PATH="$T/bin:$PATH" FM_HOME="$T/home" FM_PROCEVENT_CLAIM_ROOT="$T/claims" "$ROOT/bin/fm-procevent-lavish.sh" arm "$T/board.html" >"$T/out" 2>"$T/err" & p=$!
while kill -0 $p 2>/dev/null && [ $((SECONDS-start)) -lt 20 ]; do sleep 0.2; done
if kill -0 $p 2>/dev/null; then kill -TERM $p; wait $p 2>/dev/null; echo "RESULT: arm HUNG past 20s (listener cannot reconnect)"
else wait $p; echo "RESULT: arm exit=$? after $((SECONDS-start))s"; fi
echo "stdout:"; sed "s/$id/<src>/g" "$T/out" | head -5; echo "stderr:"; sed "s/$id/<src>/g" "$T/err" | head -5
echo "== after: lock dirs"; (cd "$T/claims" && ls -d *.lock* 2>/dev/null | sed "s/$id/<src>/" || echo "(none)")
echo "== registration still present:"; ls "$T/home/state/procevent/$id.source" >/dev/null && echo yes
PATH="$T/bin:$PATH" FM_HOME="$T/home" "$ROOT/bin/fm-procevent.sh" retire "$id" >/dev/null 2>&1
trash "$T" 2>/dev/null || rm -rf "$T"
