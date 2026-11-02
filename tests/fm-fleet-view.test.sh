#!/usr/bin/env bash
# Fleet rendering over local snapshot fixtures without live fleet access.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-fleet-view.sh" "$TMP/fm-fleet-view.sh"
export VIEW_FIXTURE="$TMP"
cat > "$TMP/fm-fleet-snapshot.sh" <<'SNAPSHOT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$VIEW_FIXTURE/args"
cat "$VIEW_FIXTURE/snapshot"
exit "$(cat "$VIEW_FIXTURE/status")"
SNAPSHOT
chmod +x "$TMP/fm-fleet-snapshot.sh"
printf '0\n' > "$TMP/status"
cat > "$TMP/snapshot" <<'JSON'
{"schema":"v1","fm_home":"/fixture","tasks":[],"backlog":{"records":[]},"secondmate_guidance":{"note":"Use the return channel."}}
JSON

contains() {
  case "$OUTPUT" in *"$1"*) ;; *) fail "missing output: $1" ;; esac
}

test_empty() {
  OUTPUT=$(bash "$TMP/fm-fleet-view.sh") || fail "empty render"
  contains 'Schema: v1'
  contains 'Home: /fixture'
  contains 'No live task metadata found.'
  contains 'No queued backlog records found.'
  contains 'No done backlog records found.'
  contains 'Use the return channel.'
  [ "$(cat "$TMP/args")" = --json ] || fail "snapshot arguments"
  pass "empty sections and snapshot metadata render"
}

test_rows() {
  cat > "$TMP/snapshot" <<'JSON'
{"schema":"v1","fm_home":"/fixture","tasks":[
{"id":"ship","kind":"ship","current_state":{"state":"ready","source":"meta"},"backlog":{"repo":"repo"},"backend":"local","endpoint":{"exists":true},"pr":{"url":"https://example.test/pr"},"paths":{"home":{},"worktree":{"path":"/work","present":false}},"actions":{"watch":"watch ship"}},
{"id":"mate","kind":"secondmate","current_state":{"state":"idle","source":"meta"},"project":"project","backend":"remote","endpoint":{"exists":false,"agent_alive":false},"paths":{"home":{"path":"/home","present":true},"report":{"present":true,"path":"/report"}},"actions":{"send":"send mate","watch":"watch mate"}},
{"id":"unknown","kind":"scout","current_state":{"state":"active","source":"meta"},"backend":"local","endpoint":{},"paths":{},"actions":{"watch":"watch scout"}}
],"backlog":{"records":[
{"state":"queued","id":"q","title":"Queued title","repo":"repo","kind":"ship","blocked_by":"dep","blocked_reason":"waiting","local_note":"local"},
{"state":"done","id":"d","raw":"Raw title","report_path":"/done"},
{"state":"active","title":"HIDDEN"}
]},"secondmate_guidance":{"note":"Return here."}}
JSON
  OUTPUT=$(bash "$TMP/fm-fleet-view.sh") || fail "populated render"
  contains '| ship | ready / meta | ship | repo | local | present | https://example.test/pr | /work (absent) | watch ship |'
  contains '| mate | idle / meta | secondmate | project | remote | absent / false | /report | /home | send mate - watch mate |'
  contains '| unknown | active / meta | scout | - | local | unknown | - | - | watch scout |'
  contains '| q | Queued title | repo | ship | dep - waiting | local |'
  contains '| d | Raw title | - | - | - | /done |'
  case "$OUTPUT" in *HIDDEN*) fail "unselected backlog record rendered" ;; esac
  pass "task kinds, endpoint states, artifact priorities, paths and backlog filtering render"
}

test_transport() {
  local rc
  bash "$TMP/fm-fleet-view.sh" --json > "$TMP/output" || fail "JSON passthrough"
  cmp -s "$TMP/snapshot" "$TMP/output" || fail "JSON changed"
  printf '7\n' > "$TMP/status"
  bash "$TMP/fm-fleet-view.sh" > "$TMP/output"
  rc=$?
  [ "$rc" -eq 7 ] && [ ! -s "$TMP/output" ] || fail "render failure propagation"
  bash "$TMP/fm-fleet-view.sh" --json > /dev/null
  [ "$?" -eq 7 ] || fail "JSON failure propagation"
  bash "$TMP/fm-fleet-view.sh" --help > "$TMP/output" || fail "help status"
  bash "$TMP/fm-fleet-view.sh" --invalid > "$TMP/output" 2> "$TMP/error"
  rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$TMP/output" ] && [ -s "$TMP/error" ] || fail "invalid option handling"
  pass "JSON bytes, snapshot failures, help and invalid options preserve their contracts"
}

test_empty
test_rows
test_transport
