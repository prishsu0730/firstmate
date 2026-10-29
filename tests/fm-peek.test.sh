#!/usr/bin/env bash
# Peek routing without backend servers or remote connections.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-peek.sh" "$TMP/fm-peek.sh"
export PEEK_FIXTURE="$TMP" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records"
cat > "$TMP/fm-backend.sh" <<'BACKEND'
fm_backend_meta_for_selector() {
  printf '%s\n' "$@" > "$PEEK_FIXTURE/meta-args"
  [ "$1" = remote ] || return 1
  printf '%s/remote.meta\n' "$2"
}
fm_meta_get() { printf 'example.invalid\n'; }
fm_backend_resolve_selector() { printf 'resolved endpoint\n'; }
fm_backend_of_selector() { printf 'test-backend\n'; }
fm_backend_expected_label_of_selector() { printf 'expected label\n'; }
fm_backend_capture() {
  printf '%s\n' "$@" > "$PEEK_FIXTURE/capture-args"
  printf 'local capture\n'
  return "$(cat "$PEEK_FIXTURE/status")"
}
BACKEND
cat > "$TMP/fm-guard.sh" <<'GUARD'
#!/usr/bin/env bash
exit 1
GUARD
cat > "$TMP/fm-on.sh" <<'REMOTE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PEEK_FIXTURE/remote-args"
printf '%s\n' "$FM_HOME" > "$PEEK_FIXTURE/remote-home"
if read -r unused; then exit 99; fi
printf 'remote capture\n'
exit "$(cat "$PEEK_FIXTURE/status")"
REMOTE
chmod +x "$TMP/fm-guard.sh" "$TMP/fm-on.sh"
printf '0\n' > "$TMP/status"

test_local() {
  local output rc
  output=$(bash "$TMP/fm-peek.sh" 'local selector')
  rc=$?
  [ "$rc" -eq 0 ] || fail "local status"
  [ "$output" = 'local capture' ] || fail "local output"
  [ "$(cat "$TMP/meta-args")" = "$(printf '%s\n' 'local selector' "$FM_STATE_OVERRIDE")" ] || fail "selector and state boundaries"
  [ "$(cat "$TMP/capture-args")" = "$(printf '%s\n' test-backend 'resolved endpoint' 40 'expected label')" ] || fail "local default capture arguments"
  printf '7\n' > "$TMP/status"
  bash "$TMP/fm-peek.sh" local 12 > /dev/null
  rc=$?
  [ "$rc" -eq 7 ] || fail "local capture failure status"
  [ "$(cat "$TMP/capture-args")" = "$(printf '%s\n' test-backend 'resolved endpoint' 12 'expected label')" ] || fail "explicit local lines"
  printf '0\n' > "$TMP/status"
  pass "local capture preserves arguments, output and status despite guard failure"
}

test_remote() {
  local output lines expected
  for lines in 1 100 101 0 invalid; do
    expected=$lines
    case "$lines" in 101) expected=100 ;; 0|invalid) expected=40 ;; esac
    output=$(bash "$TMP/fm-peek.sh" remote "$lines") || fail "remote capture status"
    [ "$output" = 'remote capture' ] || fail "remote output"
    [ "$(cat "$TMP/remote-args")" = "$(printf '%s\n' remote fm-remote-secondmate-control.sh capture remote "$expected")" ] || fail "remote line normalization for $lines"
    [ "$(cat "$TMP/remote-home")" = "$FM_HOME" ] || fail "remote home forwarding"
  done
  pass "remote capture clamps lines, defaults invalid values and closes stdin"
}

test_remote_failure() {
  local rc before
  before=$(cat "$TMP/capture-args")
  printf '8\n' > "$TMP/status"
  bash "$TMP/fm-peek.sh" remote > "$TMP/stdout" 2> "$TMP/stderr"
  rc=$?
  [ "$rc" -eq 1 ] || fail "remote failure normalized status"
  case "$(cat "$TMP/stderr")" in *remote*example.invalid*'not thereby dead'*) ;; *) fail "remote diagnostic" ;; esac
  [ "$(cat "$TMP/capture-args")" = "$before" ] || fail "remote failure fell through to local capture"
  pass "remote failure names the host and does not fall through to local capture"
}

test_local
test_remote
test_remote_failure
