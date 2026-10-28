#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml sets commands.test to exactly the colocated
# test wrapper and nothing else. Any other value - a suite walk, a family, a
# fixed script list, or the wrapper with extra arguments or chained commands -
# is rejected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
WRAPPER_COMMAND='bin/fm-nm-test.sh'

nm_commands_test() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
print val.is_a?(String) ? val : (val.nil? ? "" : val.inspect)
' "$NM" || fail "failed to parse .no-mistakes.yaml as YAML"
}

test_nm_test_command_is_exactly_the_colocated_wrapper() {
  local val
  val=$(nm_commands_test)
  assert_equals "$WRAPPER_COMMAND" "$val" \
    "commands.test must be exactly the colocated-test wrapper, not a suite walk, family, or fixed list"
  pass "commands.test is exactly $WRAPPER_COMMAND"
}

test_wrapper_is_executable_and_selects_only_existing_tests() {
  local out line
  [ -x "$ROOT/$WRAPPER_COMMAND" ] || fail "$WRAPPER_COMMAND must be executable"
  out=$(cd "$ROOT" && "$ROOT/$WRAPPER_COMMAND" --list 2>/dev/null) \
    || fail "$WRAPPER_COMMAND --list must succeed on this checkout"
  [ -n "$out" ] || fail "$WRAPPER_COMMAND --list must always select at least the fallback"
  while IFS= read -r line; do
    case "$line" in
      tests/*.test.sh) [ -f "$ROOT/$line" ] || fail "selected test does not exist: $line" ;;
      *) fail "selected a non-test path: $line" ;;
    esac
  done <<<"$out"
  pass "wrapper lists only existing tests/*.test.sh scripts"
}

test_nm_test_command_is_exactly_the_colocated_wrapper
test_wrapper_is_executable_and_selects_only_existing_tests
