#!/usr/bin/env bash
# Restart capability from durable records without runtime services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$ROOT/bin/fm-secondmate-restart-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
RECORD="$TMP/mate.meta"

write_record() {
  printf '%s\n' kind=secondmate window=mate-endpoint "harness=$1" > "$RECORD"
  shift
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >> "$RECORD"
}

refuses() {
  fm_secondmate_restart_capable "$1" && fail "record accepted: $2"
  [ -n "$FM_SECONDMATE_RESTART_REASON" ] || fail "missing refusal reason: $2"
  [ -z "$FM_SECONDMATE_RESTART_HARNESS" ] || fail "stale harness: $2"
}

test_record_safety() {
  write_record claude
  fm_secondmate_restart_capable "$RECORD" || fail "initial valid record"
  refuses "$TMP/missing" missing
  [ -z "$FM_SECONDMATE_RESTART_PLACEMENT$FM_SECONDMATE_RESTART_BACKEND$FM_SECONDMATE_RESTART_HOST" ] || fail "stale outputs after missing record"
  refuses "$TMP" directory
  ln -s "$RECORD" "$TMP/link"
  refuses "$TMP/link" symlink
  printf '%s\n' kind=ship window=endpoint harness=claude > "$RECORD"
  refuses "$RECORD" wrong-kind
  printf '%s\n' kind=secondmate harness=claude > "$RECORD"
  refuses "$RECORD" missing-endpoint
  pass "missing, non-file, symlink, wrong-kind and endpoint-free records refuse"
}

test_local_capability() {
  local backend
  for backend in '' tmux herdr; do
    write_record codex-custom "backend=$backend"
    fm_secondmate_restart_capable "$RECORD" || fail "local backend: $backend"
    [ "$FM_SECONDMATE_RESTART_PLACEMENT" = local ] || fail "local placement"
    [ "$FM_SECONDMATE_RESTART_BACKEND" = "${backend:-tmux}" ] || fail "local backend result"
    [ "$FM_SECONDMATE_RESTART_HARNESS" = codex ] || fail "harness family normalization"
    [ -z "$FM_SECONDMATE_RESTART_HOST$FM_SECONDMATE_RESTART_REASON" ] || fail "local success leaves diagnostics"
  done
  for backend in zellij orca cmux unknown; do
    write_record claude "backend=$backend"
    refuses "$RECORD" "$backend"
    [ "$FM_SECONDMATE_RESTART_BACKEND" = "$backend" ] || fail "refused backend result"
  done
  pass "local default and verified backends resolve while unverified backends refuse"
}

test_remote_capability() {
  write_record pi remote_host=example.invalid backend=zellij
  fm_secondmate_restart_capable "$RECORD" || fail "remote default backend"
  [ "$FM_SECONDMATE_RESTART_PLACEMENT" = remote ] || fail "remote placement"
  [ "$FM_SECONDMATE_RESTART_HOST" = example.invalid ] || fail "remote host"
  [ "$FM_SECONDMATE_RESTART_BACKEND" = herdr ] || fail "remote default overrides local backend"
  write_record pi remote_host=example.invalid remote_backend=herdr
  fm_secondmate_restart_capable "$RECORD" || fail "explicit remote backend"
  write_record pi remote_host=example.invalid remote_backend=cmux backend=tmux
  refuses "$RECORD" remote-unverified
  [ "$FM_SECONDMATE_RESTART_BACKEND" = cmux ] || fail "remote backend precedence"
  write_record claude
  fm_secondmate_restart_capable "$RECORD" || fail "local after remote refusal"
  [ -z "$FM_SECONDMATE_RESTART_HOST$FM_SECONDMATE_RESTART_REASON" ] || fail "stale remote host or refusal"
  pass "remote routing uses its recorded backend and resets outputs on subsequent calls"
}

test_harness_capability() {
  local harness
  for harness in claude codex opencode pi pi-signed grok kimi cursor omp; do
    write_record "$harness"
    fm_secondmate_restart_capable "$RECORD" || fail "supported secondmate: $harness"
    [ "$FM_SECONDMATE_RESTART_HARNESS" = "$harness" ] || fail "resolved secondmate: $harness"
  done
  for harness in muse gemini rovo agy devin unknown '' pi-other; do
    write_record "$harness"
    refuses "$RECORD" "unsupported secondmate: $harness"
  done
  pass "secondmate adapters accept and worker-only or unknown adapters refuse"
}

test_record_safety
test_local_capability
test_remote_capability
test_harness_capability
