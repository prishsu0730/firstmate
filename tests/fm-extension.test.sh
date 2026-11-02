#!/usr/bin/env bash
# Extension shell routing without remote connections or package installation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-extension.sh" "$TMP/fm-extension.sh"
export EXTENSION_FIXTURE="$TMP"
cat > "$TMP/fm-extension.mjs" <<'EXTENSION'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$EXTENSION_FIXTURE/extension-args"
printf 'package payload\n'
exit "$(cat "$EXTENSION_FIXTURE/extension-status")"
EXTENSION
cat > "$TMP/fm-on.sh" <<'REMOTE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$EXTENSION_FIXTURE/remote-args"
cat > "$EXTENSION_FIXTURE/payload"
printf 'remote result\n'
exit "$(cat "$EXTENSION_FIXTURE/remote-status")"
REMOTE
chmod +x "$TMP/fm-extension.mjs" "$TMP/fm-on.sh"
printf '0\n' > "$TMP/extension-status"
printf '0\n' > "$TMP/remote-status"

test_local() {
  local output rc
  output=$(bash "$TMP/fm-extension.sh" bind '/package with spaces' --label 'two words')
  rc=$?
  [ "$rc" -eq 0 ] || fail "local invocation returned $rc"
  [ "$output" = 'package payload' ] || fail "local stdout"
  [ "$(cat "$TMP/extension-args")" = "$(printf '%s\n' bind '/package with spaces' --label 'two words')" ] || fail "local argument boundaries"
  [ ! -e "$TMP/remote-args" ] || fail "local invocation used remote"
  printf '7\n' > "$TMP/extension-status"
  bash "$TMP/fm-extension.sh" > /dev/null
  rc=$?
  [ "$rc" -eq 7 ] || fail "local failure status"
  printf '0\n' > "$TMP/extension-status"
  pass "local arguments, output and failure status pass through"
}

test_usage() {
  local rc
  bash "$TMP/fm-extension.sh" remote-bind route package > "$TMP/stdout" 2> "$TMP/stderr"
  rc=$?
  [ "$rc" -eq 2 ] || fail "incomplete remote-bind status"
  [ ! -s "$TMP/stdout" ] || fail "usage on stdout"
  case "$(cat "$TMP/stderr")" in usage:*remote-bind*) ;; *) fail "missing usage diagnostic" ;; esac
  [ ! -e "$TMP/remote-args" ] || fail "incomplete invocation reached remote"
  pass "remote-bind requires a route, package root and bind option"
}

test_remote() {
  local output rc
  output=$(bash "$TMP/fm-extension.sh" remote-bind 'remote route' '/package root' --label 'two words')
  rc=$?
  [ "$rc" -eq 0 ] || fail "remote invocation returned $rc"
  [ "$output" = 'remote result' ] || fail "remote stdout"
  [ "$(cat "$TMP/extension-args")" = "$(printf '%s\n' pack-transfer '/package root')" ] || fail "pack arguments"
  [ "$(cat "$TMP/remote-args")" = "$(printf '%s\n' --stdin 'remote route' fm-extension.sh receive-transfer-bind --label 'two words')" ] || fail "remote argument boundaries"
  [ "$(cat "$TMP/payload")" = 'package payload' ] || fail "package stream"
  printf '8\n' > "$TMP/extension-status"
  bash "$TMP/fm-extension.sh" remote-bind route package --option > /dev/null
  rc=$?
  [ "$rc" -eq 8 ] || fail "pack failure hidden by successful remote"
  printf '0\n' > "$TMP/extension-status"
  printf '9\n' > "$TMP/remote-status"
  bash "$TMP/fm-extension.sh" remote-bind route package --option > /dev/null
  rc=$?
  [ "$rc" -eq 9 ] || fail "remote failure status"
  pass "remote-bind streams the package, preserves arguments and propagates either pipeline failure"
}

test_local
test_usage
test_remote
