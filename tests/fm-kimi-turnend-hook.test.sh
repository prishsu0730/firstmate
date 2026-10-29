#!/usr/bin/env bash
# Kimi hook installation without a live harness or user configuration.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT

run_hook() { HOME="$TMP/home" bash "$ROOT/bin/fm-kimi-turnend-hook.sh" "$@"; }
mkdir -p "$TMP/home/.kimi-code"
CONFIG="$TMP/home/.kimi-code/config.toml"

test_roundtrip() {
  local ending
  for ending in '' $'\n'; do
    printf '# preserved comment\nmodel = "example"%s' "$ending" > "$CONFIG"
    cat "$CONFIG" > "$TMP/original"
    chmod 640 "$CONFIG"
    run_hook install || fail 'install'
    python3 - "$CONFIG" <<'PY' || fail 'installed config and private permissions'
import os, stat, sys, tomllib
path = sys.argv[1]
with open(path, 'rb') as stream:
    config = tomllib.load(stream)
assert config['model'] == 'example'
assert len(config['hooks']) == 1
assert config['hooks'][0]['event'] == 'Stop'
assert stat.S_IMODE(os.stat(path).st_mode) == 0o640
for name in ('fm-turn-end.sh', 'fm-turn-end.d'):
    assert stat.S_IMODE(os.stat(os.path.join(os.path.dirname(path), name)).st_mode) == 0o700
PY
    cat "$CONFIG" > "$TMP/installed"
    run_hook install || fail 'repeat install'
    cmp -s "$CONFIG" "$TMP/installed" || fail 'install not idempotent'
    run_hook remove || fail 'remove'
    cmp -s "$CONFIG" "$TMP/original" || fail 'original bytes not restored'
    [ ! -e "$TMP/home/.kimi-code/fm-turn-end.sh" ] || fail 'hook remains'
    [ ! -e "$TMP/home/.kimi-code/fm-turn-end.d" ] || fail 'registry remains'
    run_hook remove || fail 'repeat remove'
  done
  pass 'installation is idempotent and removal restores bytes and removes owned files'
}

test_refusals() {
  local body
  for body in 'broken = [' 'hooks = "unexpected"' '# BEGIN FIRSTMATE KIMI TURN-END HOOK' 'command = "fm-turn-end.sh"'; do
    printf '%s\n' "$body" > "$CONFIG"
    cat "$CONFIG" > "$TMP/original"
    run_hook install > "$TMP/out" 2> "$TMP/err" && fail 'unsafe config accepted'
    cmp -s "$CONFIG" "$TMP/original" || fail 'refusal changed config'
    [ ! -e "$TMP/home/.kimi-code/fm-turn-end.sh" ] || fail 'refusal created hook'
    [ -s "$TMP/err" ] || fail 'missing refusal diagnostic'
  done
  pass 'malformed TOML, unexpected hooks, partial markers and foreign references refuse without writes'
}

test_passive_hook() {
  printf 'model = "example"\n' > "$CONFIG"
  run_hook install || fail 'passive hook install'
  mkdir "$TMP/work"
  printf 'token=fm.ABCdef123456\n' > "$TMP/work/.fm-kimi-turnend"
  printf '%s\n' "$TMP/task.turn-ended" > "$TMP/home/.kimi-code/fm-turn-end.d/fm.ABCdef123456"
  printf '{"hook_event_name":"Stop","cwd":"%s"}\n' "$TMP/work" |
    HOME="$TMP/home" bash "$TMP/home/.kimi-code/fm-turn-end.sh" > "$TMP/out" 2> "$TMP/err" || fail 'hook status'
  [ -f "$TMP/task.turn-ended" ] || fail 'authorized marker missing'
  [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || fail 'hook not silent'
  run_hook remove || fail 'passive hook remove'
  pass 'installed hook silently records an authorized Stop event'
}

test_roundtrip
test_refusals
test_passive_hook
