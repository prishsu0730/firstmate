#!/usr/bin/env bash
# Cursor hook transport without launching a session or harness.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-sessionstart-cursor.sh" "$TMP/fm-sessionstart-cursor.sh"
export HOOK_FIXTURE="$TMP"
cat > "$TMP/fm-sessionstart-run.sh" <<'RUN'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HOOK_FIXTURE/args"
if IFS= read -r line; then
  printf 'unexpected stdin: %s\n' "$line" > "$HOOK_FIXTURE/stdin"
fi
printf 'hidden diagnostic\n' >&2
cat "$HOOK_FIXTURE/digest"
exit "$(cat "$HOOK_FIXTURE/status")"
RUN
chmod +x "$TMP/fm-sessionstart-run.sh"
printf '0\n' > "$TMP/status"

expect() {
  local source=$1 output rc
  shift
  output=$(printf 'caller input\n' | bash "$TMP/fm-sessionstart-cursor.sh" "$@" 2> "$TMP/stderr")
  rc=$?
  [ "$rc" -eq 0 ] || fail "hook returned $rc"
  [ ! -s "$TMP/stderr" ] || fail "hook leaked diagnostic"
  [ ! -e "$TMP/stdin" ] || fail "hook forwarded stdin"
  [ "$(cat "$TMP/args")" = "$(printf '%s\n' --source "$source")" ] || fail "source forwarding"
  if [ -s "$TMP/digest" ]; then
    printf '%s\n' "$output" | jq -e --rawfile digest "$TMP/digest" \
      '. == {additional_context: ($digest | sub("\n+$"; ""))}' >/dev/null || fail "digest JSON"
  else
    [ -z "$output" ] || fail "empty digest emitted output"
  fi
}

test_arguments() {
  printf 'digest\n' > "$TMP/digest"
  expect ''
  expect startup --source startup
  expect resume --source=resume
  expect last ignored --source first --unknown --source=last
  expect '' --source
  pass "missing, separate, equals and repeated source arguments forward correctly"
}

test_digest() {
  printf 'first "quoted" line\nsecond \\ line\n\n' > "$TMP/digest"
  expect startup --source startup
  printf '7\n' > "$TMP/status"
  expect startup --source startup
  pass "multiline digests preserve JSON content even when the runner fails"
}

test_empty() {
  : > "$TMP/digest"
  expect startup --source startup
  printf '0\n' > "$TMP/status"
  expect startup --source startup
  pass "empty successful and failed digests emit nothing and always exit zero"
}

test_arguments
test_digest
test_empty
