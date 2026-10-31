#!/usr/bin/env bash
# Pure Gemini path and command-line parsing validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-gemini-lib.sh
. "$ROOT/bin/fm-gemini-lib.sh"

test_paths() {
  local path got rc
  for path in gemini /usr/bin/gemini '/path with spaces/gemini' /lib/@google/gemini-cli/dist/index.js; do
    got=$(fm_gemini_path_is_gemini "$path"); rc=$?
    [ "$rc" -eq 0 ] || fail "accepted path: $path"
    [ -z "$got" ] || fail "accepted path is silent"
  done
  for path in '' node MainThread /work/gemini/script.js /bin/gemini-other /lib/@google/gemini-cli /lib/@google/gemini-cli-other/index.js --gemini -/gemini; do
    got=$(fm_gemini_path_is_gemini "$path"); rc=$?
    [ "$rc" -eq 1 ] || fail "rejected path: [$path]"
    [ -z "$got" ] || fail "rejected path is silent"
  done
  pass "exact executable and package paths match while lookalikes are rejected silently"
}

test_accepted_args() {
  local args got rc
  for args in 'gemini -y' '/usr/bin/gemini --prompt hello' 'node /bin/gemini -y' 'node --max-old-space-size=10000 /bin/gemini' 'node-24 /bin/gemini' 'node24 /bin/gemini' 'node --prompt gemini /bin/gemini' 'MainThread /lib/@google/gemini-cli/dist/index.js' $' \t/usr/bin/node\t--flag\t/bin/gemini\n'; do
    got=$(fm_gemini_args_are_gemini "$args"); rc=$?
    [ "$rc" -eq 0 ] || fail "accepted arguments: [$args]"
    [ -z "$got" ] || fail "accepted arguments are silent"
  done
  pass "native commands and interpreter script arguments accept flags and whitespace"
}

test_rejected_args() {
  local args got rc
  for args in '' '   ' node 'node --flag' 'python /bin/gemini' 'echo gemini' 'node other.js gemini' 'node other.js /bin/gemini' 'node /work/gemini/other.js' '/bin/gemini-other' 'NODE /bin/gemini'; do
    got=$(fm_gemini_args_are_gemini "$args"); rc=$?
    [ "$rc" -eq 1 ] || fail "rejected arguments: [$args]"
    [ -z "$got" ] || fail "rejected arguments are silent"
  done
  pass "missing scripts, unrelated interpreters, and later Gemini mentions are refused silently"
}

test_unavailable_pid() {
  local pid got rc
  for pid in firstmate-no-such-process -1 not-a-pid; do
    got=$(fm_gemini_pid_is_gemini "$pid"); rc=$?
    [ "$rc" -eq 1 ] || fail "unavailable process: [$pid]"
    [ -z "$got" ] || fail "unavailable process is silent"
  done
  pass "processes without readable proc command lines are refused silently"
}

test_paths
test_accepted_args
test_rejected_args
test_unavailable_pid
