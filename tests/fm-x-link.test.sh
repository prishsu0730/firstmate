#!/usr/bin/env bash
# Link validation and carried reply context without contacting the relay.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records" FM_DATA_OVERRIDE="$TMP/registry"
export FMX_ENV_FILE="$TMP/absent-env" FMX_PAIRING_TOKEN='' FMX_DRY_RUN=1
mkdir -p "$FM_HOME" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" "$TMP/tools"
cat > "$TMP/tools/curl" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected network call\n' > "$FM_HOME/network-call"
exit 99
STUB
chmod +x "$TMP/tools/curl"
export PATH="$TMP/tools:$PATH"
link_task() { bash "$ROOT/bin/fm-x-link.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"; }
expect_status() {
  local expected=$1 rc
  shift
  link_task "$@"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc: $(cat "$TMP/stderr")"
}
write_meta() {
  printf 'harness=codex\nproject=demo\nx_request=old\nx_request_ts=1\nx_followups=2\nx_platform=discord\nx_reply_max_chars=2000\n' > "$FM_STATE_OVERRIDE/task.meta"
}

test_validation() {
  local value
  write_meta
  expect_status 2
  expect_status 2 task
  expect_status 2 task request --unknown
  for value in ../escape .hidden 'bad/name' 'has space'; do
    expect_status 2 "$value" request
    expect_status 2 task "$value"
  done
  expect_status 2 task request --carry-count 1
  expect_status 2 task request --carry-ts 123
  expect_status 2 task request --carry-platform x
  expect_status 2 task request --carry-max 50
  expect_status 2 task request --carry-count -1 --carry-ts 123
  expect_status 2 task request --carry-count 0 --carry-ts abc
  expect_status 2 task request --carry-count 0 --carry-ts 123 --carry-platform other
  expect_status 2 task request --carry-count 0 --carry-ts 123 --carry-max 49
  expect_status 2 task request --carry-count 0 --carry-ts 123
  [ "$(cat "$FM_STATE_OVERRIDE/task.meta")" = "$(printf 'harness=codex\nproject=demo\nx_request=old\nx_request_ts=1\nx_followups=2\nx_platform=discord\nx_reply_max_chars=2000')" ] || fail 'refusal changed metadata'
  pass 'unsafe ids, malformed carry arguments and incomplete reply context preserve metadata'
}

test_carry() {
  local expected
  expect_status 0 task request --carry-count 3 --carry-ts 123 --carry-platform twitter --carry-max 50
  expected=$(printf 'harness=codex\nproject=demo\nx_request=request\nx_request_ts=123\nx_followups=3\nx_platform=x\nx_reply_max_chars=50')
  [ "$(cat "$FM_STATE_OVERRIDE/task.meta")" = "$expected" ] || fail 'carried values or unrelated fields changed'
  [ "$(cat "$TMP/stdout")" = 'linked task to X request request' ] || fail 'link confirmation'
  expect_status 0 task successor --carry-count 0 --carry-ts 456 --carry-platform discord --carry-max 2000
  expected=$(printf 'harness=codex\nproject=demo\nx_request=successor\nx_request_ts=456\nx_followups=0\nx_platform=discord\nx_reply_max_chars=2000')
  [ "$(cat "$FM_STATE_OVERRIDE/task.meta")" = "$expected" ] || fail 'replacement retained old binding'
  pass 'relink preserves original budgets and timestamps, normalizes twitter and replaces prior bindings'
}

test_missing() {
  expect_status 1 absent request
  case "$(cat "$TMP/stderr")" in *'no such task: state/absent.meta'*) ;; *) fail 'missing task diagnostic' ;; esac
  [ ! -e "$FM_STATE_OVERRIDE/absent.meta" ] || fail 'missing task created'
  [ ! -e "$FM_HOME/network-call" ] || fail 'contacted relay'
  pass 'missing local records are refused and carried links never contact the relay'
}

test_validation
test_carry
test_missing
