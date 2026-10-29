#!/usr/bin/env bash
# Pure backend-neutral process classification validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"

assert_name() {
  local expected=$1 name=$2 got
  got=$(fm_agent_process_classify_name "$name")
  [ "$got" = "$expected" ] || fail "name $name: expected $expected, got $got"
}

test_names() {
  local name
  for name in muse muse-bin-1.2 omp agy devin pi pi-signed pi-launcher Pi claude codex opencode grok kimi rovo; do
    assert_name agent "/opt/tools/$name"
  done
  for name in musescore amuse ompd comp agyn devin-helper python node agent ''; do
    assert_name other "$name"
  done
  pass "agent names and anchored lookalikes are distinguished"
}

test_shell_names() {
  local name
  for name in zsh bash sh dash ash ksh mksh tcsh csh fish; do
    assert_name shell "$name"
    assert_name shell "/bin/$name"
    assert_name shell "-$name"
  done
  assert_name other bashful
  assert_name other --bash
  pass "shell paths and login prefixes are recognized exactly"
}

test_combined_identity() {
  local got
  got=$(fm_agent_process_classify bash codex ''); [ "$got" = agent ] || fail "argv0 agent wins"
  got=$(fm_agent_process_classify codex bash ''); [ "$got" = agent ] || fail "name agent wins"
  got=$(fm_agent_process_classify bash /bin/zsh ''); [ "$got" = shell ] || fail "agreeing shell surfaces"
  got=$(fm_agent_process_classify bash '' ''); [ "$got" = shell ] || fail "missing argv0 shell fallback"
  got=$(fm_agent_process_classify bash python ''); [ "$got" = other ] || fail "mixed shell and other"
  got=$(fm_agent_process_classify python bash ''); [ "$got" = other ] || fail "mixed other and shell"
  got=$(fm_agent_process_classify node node 'node unrelated.js --mention codex'); [ "$got" = other ] || fail "incidental args"
  got=$(fm_agent_process_classify '' '' ''; printf sentinel)
  [ "$got" = othersentinel ] || fail "exact output without newline"
  pass "combined identities prefer agents and require shell agreement"
}

test_names
test_shell_names
test_combined_identity
