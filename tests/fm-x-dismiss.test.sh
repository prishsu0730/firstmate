#!/usr/bin/env bash
# Dismiss validation and private previews without a relay connection.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records"
export FMX_ENV_FILE="$TMP/absent-env" FMX_PAIRING_TOKEN='' FMX_DRY_RUN=1
export FMX_RELAY_URL=https://relay.invalid/
mkdir -p "$TMP/tools" "$FM_STATE_OVERRIDE/x-context"
cat > "$TMP/tools/curl" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected network call\n' > "$FM_HOME/network-call"
exit 99
STUB
chmod +x "$TMP/tools/curl"
mkdir -p "$FM_HOME"
export PATH="$TMP/tools:$PATH"
dismiss() { bash "$ROOT/bin/fm-x-dismiss.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"; }
expect_status() {
  local expected=$1 rc
  shift
  dismiss "$@"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc"
}

test_validation() {
  local request
  expect_status 2
  expect_status 2 --help
  expect_status 2 valid extra
  for request in .hidden ../escape 'bad/name' 'has space' 'bad?'; do
    expect_status 2 "$request"
  done
  [ ! -e "$FM_STATE_OVERRIDE/x-outbox" ] || fail 'invalid request created outbox'
  pass 'missing, extra, option and unsafe request arguments are refused before publication'
}

test_preview() {
  printf '{}\n' > "$FM_STATE_OVERRIDE/x-context/req_1.a-b.json"
  printf '{"keep":true}\n' > "$FM_STATE_OVERRIDE/x-context/other.json"
  expect_status 0 req_1.a-b
  [ "$(cat "$TMP/stdout")" = req_1.a-b ] || fail 'request id stdout'
  jq -e '. == {request_id:"req_1.a-b",endpoint:"dismiss"}' \
    "$FM_STATE_OVERRIDE/x-outbox/req_1.a-b.json" >/dev/null || fail 'preview payload'
  python3 - "$FM_STATE_OVERRIDE/x-outbox/req_1.a-b.json" <<'PY' || fail 'private outbox mode'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
  [ ! -e "$FM_STATE_OVERRIDE/x-context/req_1.a-b.json" ] || fail 'dismissed context retained'
  [ "$(cat "$FM_STATE_OVERRIDE/x-context/other.json")" = '{"keep":true}' ] || fail 'unrelated context changed'
  case "$(cat "$TMP/stderr")" in
    *'DRY RUN - would POST to https://relay.invalid/connector/dismiss'*) ;;
    *) fail 'preview diagnostic and relay normalization' ;;
  esac
  expect_status 0 req_1.a-b
  pass 'token-free previews publish private JSON, clear only matching context and support repeats'
}

test_missing_token() {
  printf '{}\n' > "$FM_STATE_OVERRIDE/x-context/live.json"
  FMX_DRY_RUN=off expect_status 1 live
  [ -e "$FM_STATE_OVERRIDE/x-context/live.json" ] || fail 'failed dismiss cleared context'
  [ ! -e "$FM_STATE_OVERRIDE/x-outbox/live.json" ] || fail 'live refusal created preview'
  case "$(cat "$TMP/stderr")" in *'no FMX_PAIRING_TOKEN'*) ;; *) fail 'missing token diagnostic' ;; esac
  [ ! -e "$FM_HOME/network-call" ] || fail 'offline tests attempted transport'
  pass 'live requests without credentials preserve context and never invoke transport'
}

test_validation
test_preview
test_missing_token
