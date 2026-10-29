#!/usr/bin/env bash
# Branch report authorization and store forwarding without a supervision host.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
cp "$ROOT/bin/fm-branch-report.sh" "$TMP/fm-branch-report.sh"
export REPORT_FIXTURE="$TMP" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/records"
export FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=turn-1
mkdir -p "$FM_STATE_OVERRIDE"
cat > "$TMP/fm-afk-contract.sh" <<'STUB'
fm_afk_contract_away_present() { return 1; }
STUB
cat > "$TMP/fm-branch-outcome.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REPORT_FIXTURE/args"
[ ! -f "$REPORT_FIXTURE/store-fails" ] || exit 1
printf '42\n'
STUB
chmod +x "$TMP/fm-branch-outcome.sh"
write_turn() {
  printf 'turn=turn-1\nunscoped=%s\ntasks=alpha beta\nrows=7\nwake=signal: alpha\nposture=attended\n' "$1" > "$FM_STATE_OVERRIDE/.supervision-host-turn"
}
report() { bash "$TMP/fm-branch-report.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"; }
expect_status() {
  local expected=$1 rc
  shift
  report "$@"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc"
}

test_refusals() {
  write_turn 0
  expect_status 2 --task alpha --verdict unknown --summary text
  expect_status 2 --task alpha --verdict captain --summary text --silent true
  expect_status 2 --task alpha --verdict routine --summary ' '
  expect_status 2 --unknown
  FM_SUPERVISION_ACTOR=main expect_status 3 --task alpha --verdict routine --summary text
  FM_BRANCH_REPORT_TURN=old expect_status 3 --task alpha --verdict routine --summary text
  expect_status 3 --task fleet --verdict routine --summary text
  expect_status 3 --task alp --verdict routine --summary text
  [ ! -e "$TMP/args" ] || fail 'refusal touched store'
  [ ! -e "$FM_STATE_OVERRIDE/.supervision-host-receipts" ] || fail 'refusal wrote receipt'
  pass 'invalid reports, actors, expired turns and out-of-scope tasks are refused before append'
}

test_forwarding() {
  local expected
  expect_status 0 --task ' alpha ' --verdict captain --summary ' ready now '
  expected=$(printf '%s\n' append --task alpha --verdict captain --summary 'ready now' --silent false --wake 'signal: alpha')
  [ "$(cat "$TMP/args")" = "$expected" ] || fail 'normalized append arguments'
  [ "$(cat "$FM_STATE_OVERRIDE/.supervision-host-receipts")" = "$(printf 'turn-1\t42\tcaptain\talpha')" ] || fail 'receipt framing'
  case "$(cat "$TMP/stdout")" in *'MAIN processes it from its next drain'*) ;; *) fail 'attended captain output' ;; esac
  write_turn 1
  expect_status 0 --task fleet --verdict routine --summary quiet --silent true --wake ''
  expected=$(printf '%s\n' append --task fleet --verdict routine --summary quiet --silent true)
  [ "$(cat "$TMP/args")" = "$expected" ] || fail 'explicit empty wake and unscoped task'
  case "$(cat "$TMP/stdout")" in *'silent outcome remains in the outcome store'*) ;; *) fail 'silent output' ;; esac
  pass 'normalized fields, default and empty wakes, scoped and unscoped reports produce receipts'
}

test_store_failure() {
  local before
  before=$(cat "$FM_STATE_OVERRIDE/.supervision-host-receipts")
  touch "$TMP/store-fails"
  expect_status 1 --task alpha --verdict routine --summary text
  [ "$(cat "$FM_STATE_OVERRIDE/.supervision-host-receipts")" = "$before" ] || fail 'failed append wrote receipt'
  case "$(cat "$TMP/stderr")" in *'outcome store append failed'*) ;; *) fail 'store failure diagnostic' ;; esac
  pass 'store failures propagate without issuing a receipt'
}

test_refusals
test_forwarding
test_store_failure
