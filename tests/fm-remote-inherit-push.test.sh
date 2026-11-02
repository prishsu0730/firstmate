#!/usr/bin/env bash
# Inherited payload routing without remote connections or operational home writes.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-remote-inherit-push.sh" "$TMP/fm-remote-inherit-push.sh"
export INHERIT_FIXTURE="$TMP" FM_HOME="$TMP/home"
export FM_CONFIG_OVERRIDE="$TMP/settings" FM_DATA_OVERRIDE="$TMP/records"
mkdir -p "$FM_CONFIG_OVERRIDE" "$FM_DATA_OVERRIDE"
cat > "$TMP/fm-secondmate-registry-lib.sh" <<'STUB'
secondmate_registry_field() { [ "$2" = remote ] && printf '1\n'; }
STUB
cat > "$TMP/fm-config-inherit-lib.sh" <<'STUB'
fm_config_inherit_items() { printf '%s\n' config/present config/missing config/session data/captain-shared.md; }
fm_config_inherit_item_session_scoped() { [ "$1" = session ]; }
fm_config_source_present() { if [ -e "$1" ] || [ -L "$1" ]; then printf '1\n'; else printf '0\n'; fi; }
shared_captain_header_valid() { [ "$(cat "$1")" = authoritative ]; }
STUB
cat > "$TMP/fm-on.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$INHERIT_FIXTURE/args"
cat >> "$INHERIT_FIXTURE/payload"
[ ! -f "$INHERIT_FIXTURE/remote-fails" ] || exit 7
STUB
chmod +x "$TMP/fm-on.sh"
run_push() { bash "$TMP/fm-remote-inherit-push.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"; }
expect_status() {
  local expected=$1 rc
  shift
  run_push "$@"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc"
}

test_validation() {
  expect_status 2
  expect_status 1 'bad/id' 1
  expect_status 1 remote 0
  expect_status 1 remote -1
  expect_status 1 remote abc
  expect_status 1 remote 1000000000000000000
  expect_status 1 local 1
  [ ! -e "$TMP/args" ] || fail 'invalid request reached remote'
  pass 'usage, identifiers, generation bounds and local routes are refused before transfer'
}

test_payloads() {
  local hash empty_hash expected
  printf 'two lines\nsecond line\n' > "$FM_CONFIG_OVERRIDE/present"
  printf 'authoritative' > "$FM_DATA_OVERRIDE/captain-shared.md"
  hash=$(shasum -a 256 "$FM_CONFIG_OVERRIDE/present" | awk '{print $1}')
  empty_hash=$(printf '' | shasum -a 256 | awk '{print $1}')
  expect_status 0 remote 12
  expected=$(printf '%s\n' --stdin remote fm-remote-inherit.sh put config/present 22 "$hash" 12)
  [ "$(head -n 8 "$TMP/args")" = "$expected" ] || fail 'present payload metadata'
  expected=$(printf '%s\n' remote fm-remote-inherit.sh absent config/missing 0 "$empty_hash" 12)
  [ "$(sed -n '9,15p' "$TMP/args")" = "$expected" ] || fail 'absent payload metadata'
  [ "$(cat "$TMP/payload")" = "$(printf 'two lines\nsecond line\nauthoritative')" ] || fail 'payload bytes'
  [ "$(wc -l < "$TMP/args" | tr -d ' ')" -eq 30 ] || fail 'allowlist transfer count'
  : > "$TMP/args"
  : > "$TMP/payload"
  FM_CONFIG_INHERIT_LIVE=1 expect_status 0 remote 13
  [ "$(cat "$TMP/stdout")" = 'unchanged: config/session' ] || fail 'live session skip output'
  [ "$(wc -l < "$TMP/args" | tr -d ' ')" -eq 23 ] || fail 'live transfer count'
  pass 'present and absent items carry hashes, byte counts, generations and exact payloads; live pushes skip session items'
}

test_failures() {
  : > "$TMP/args"
  printf 'invalid header' > "$FM_DATA_OVERRIDE/captain-shared.md"
  expect_status 1 remote 14
  case "$(cat "$TMP/stderr")" in *'no valid primary-authoritative header'*) ;; *) fail 'shared header diagnostic' ;; esac
  ln "$FM_CONFIG_OVERRIDE/present" "$TMP/hardlink"
  : > "$TMP/args"
  expect_status 1 remote 15
  [ ! -s "$TMP/args" ] || fail 'hardlinked source transferred'
  case "$(cat "$TMP/stderr")" in *'hardlinked'*) ;; *) fail 'hardlink diagnostic' ;; esac
  unlink "$TMP/hardlink"
  touch "$TMP/remote-fails"
  expect_status 7 remote 16
  [ "$(wc -l < "$TMP/args" | tr -d ' ')" -eq 8 ] || fail 'continued after remote failure'
  pass 'invalid shared headers and hardlinks are refused and transport failures stop later transfers'
}

test_validation
test_payloads
test_failures
