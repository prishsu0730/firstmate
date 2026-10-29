#!/usr/bin/env bash
# Backend parsing and compatibility memoization without tasks-axi services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT

test_toml() {
  fm_tasks_axi_backend_from_toml "$TMP/missing" && fail "missing TOML accepted"
  printf '# ignored\nbackend = "sqlite" # comment\n[other]\nbackend = "markdown"\n' > "$TMP/backend.toml"
  [ "$(fm_tasks_axi_backend_from_toml "$TMP/backend.toml")" = sqlite ] || fail "root backend"
  printf "backend = 'markdown'\nbackend = 'sqlite'\n" > "$TMP/backend.toml"
  [ "$(fm_tasks_axi_backend_from_toml "$TMP/backend.toml")" = markdown ] || fail "first quoted backend"
  printf '[other]\nbackend = "sqlite"\n' > "$TMP/backend.toml"
  fm_tasks_axi_backend_from_toml "$TMP/backend.toml" && fail "nested backend accepted"
  printf 'backend = sqlite\n' > "$TMP/backend.toml"
  fm_tasks_axi_backend_from_toml "$TMP/backend.toml" && fail "unquoted backend accepted"
  pass "TOML parsing selects the first quoted root backend"
}

test_backend() {
  [ "$(fm_backlog_backend_value "$TMP")" = tasks-axi ] || fail "default backlog backend"
  printf ' \tmanual\n' > "$TMP/backlog-backend"
  fm_backlog_backend_manual "$TMP" || fail "manual selection"
  fm_tasks_axi_backend_available "$TMP" && fail "manual backend available"
  printf '\n' > "$TMP/backlog-backend"
  [ "$(fm_backlog_backend_value "$TMP")" = tasks-axi ] || fail "blank default"
  printf 'custom\n' > "$TMP/backlog-backend"
  [ "$(fm_backlog_backend_value "$TMP")" = custom ] || fail "custom backend preserved"
  [ "$(TASKS_AXI_BACKEND=sqlite fm_tasks_axi_backend "$TMP")" = sqlite ] || fail "environment override"
  [ -z "$(TASKS_AXI_BACKEND='' fm_tasks_axi_backend "$TMP")" ] || fail "empty environment override"
  pass "backlog selection and explicit environment overrides preserve current behavior"
}

test_memo() (
  local value
  for value in 0 1 invalid; do
    FM_TASKS_AXI_COMPATIBLE=$value
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    [ "${FM_TASKS_AXI_COMPATIBLE+x}" != x ] || fail "inherited verdict leaked"
    case "$value" in
      0) fm_tasks_axi_compatible && fail "cached refusal accepted" ;;
      1) fm_tasks_axi_compatible || fail "cached success refused" ;;
      invalid) [ -z "$FM_TASKS_AXI_COMPATIBLE_MEMO" ] || fail "invalid memo retained" ;;
    esac
  done
  # shellcheck disable=SC2329 # Called by the sourced compatibility helper.
  fm_tasks_axi_compatible_probe() { printf 'probe\n' >> "$TMP/probes"; return 0; }
  fm_tasks_axi_compatible || fail "initial probe"
  fm_tasks_axi_compatible || fail "memoized probe"
  [ "$(wc -l < "$TMP/probes" | tr -d '[:space:]')" = 1 ] || fail "probe repeated"
  FM_TASKS_AXI_COMPATIBLE_MEMO=
  # shellcheck disable=SC2329 # Called by the sourced compatibility helper.
  fm_tasks_axi_compatible_probe() { printf 'probe\n' >> "$TMP/probes"; return 1; }
  fm_tasks_axi_compatible && fail "failed probe accepted"
  fm_tasks_axi_compatible && fail "cached failed probe accepted"
  [ "$(wc -l < "$TMP/probes" | tr -d '[:space:]')" = 2 ] || fail "failed probe repeated"
  pass "inherited verdicts are consumed and positive and negative probes memoize"
)

test_toml
test_backend
test_memo
echo '# fm-tasks-axi-lib.test.sh: all assertions passed'
