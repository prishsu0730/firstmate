#!/usr/bin/env bash
# Registered delivery posture parsing without fleet or forge services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
export FM_DATA_OVERRIDE="$TMP/registry"
mkdir "$FM_DATA_OVERRIDE"
RECORD="$FM_DATA_OVERRIDE/projects.md"

expect() {
  local status=$1 expected=$2 output rc
  shift 2
  output=$(bash "$ROOT/bin/fm-project-mode.sh" "$@" 2> "$TMP/stderr")
  rc=$?
  [ "$rc" -eq "$status" ] || fail "status $rc instead of $status: $*"
  [ "$output" = "$expected" ] || fail "output '$output' instead of '$expected': $*"
}

test_defaults() {
  expect 0 'no-mistakes off' absent
  [ -s "$TMP/stderr" ] || fail "missing registry warning"
  expect 0 'fm/' --branch-prefix absent
  expect 0 none --forge absent
  printf '%s\n' '- legacy - old project' '- repo-long [local-only] - longer name' > "$RECORD"
  expect 0 'no-mistakes off' legacy
  [ ! -s "$TMP/stderr" ] || fail "legacy warning"
  expect 0 'no-mistakes off' repo
  [ -s "$TMP/stderr" ] || fail "missing project warning"
  expect 0 'fm/' --branch-prefix repo
  expect 0 none --forge repo
  pass "missing registry, unregistered names and legacy rows use safe defaults"
}

test_annotations() {
  cat > "$RECORD" <<'REGISTRY'
- app.one [branch=topic/ +yolo direct-PR] - literal punctuation
- appXone [local-only] - distinct name
- spaced project [local-only branch=] - bare branches
- conditional [no-mistakes-prod-only +yolo] - conditional policy
REGISTRY
  expect 0 'direct-PR on' app.one
  expect 0 'topic/' --branch-prefix app.one
  expect 0 'local-only off' appXone
  expect 0 'local-only off' 'spaced project'
  expect 0 '' --branch-prefix 'spaced project'
  expect 0 'no-mistakes on' conditional
  expect 0 'no-mistakes-prod-only on' --raw conditional
  expect 0 none --forge conditional
  pass "literal and spaced names, token order, empty prefixes and raw policies resolve"
}

test_forge() {
  cat > "$RECORD" <<'REGISTRY'
- review [direct-PR +yolo forge=gerrit branch=review/] - server
- empty [direct-PR forge= branch=custom/] - malformed
- unknown [no-mistakes forge=other] - unsupported
- local [local-only forge=gerrit] - incompatible
REGISTRY
  expect 0 'direct-PR off' review
  case "$(cat "$TMP/stderr")" in *'yolo is inactive'*) ;; *) fail "yolo refusal diagnostic" ;; esac
  expect 0 gerrit --forge review
  expect 0 'review/' --branch-prefix review
  local project
  for project in empty unknown local; do
    expect 3 '' "$project"
    case "$(cat "$TMP/stderr")" in refused:*) ;; *) fail "forge refusal diagnostic: $project" ;; esac
    expect 3 '' --forge "$project"
  done
  expect 0 'custom/' --branch-prefix empty
  pass "forge bindings refuse malformed or incompatible values and disable yolo"
}

test_unknown_tokens() {
  cat > "$RECORD" <<'REGISTRY'
- typo [direct-PR forg=gerrit] - near miss
- unknown [mystery +yolo branch=custom/] - unknown mode
- extra [local-only unrelated=value] - ignored annotation
REGISTRY
  expect 0 'direct-PR off' typo
  case "$(cat "$TMP/stderr")" in *'forg=gerrit'*'forge=gerrit'*) ;; *) fail "near-miss diagnostic" ;; esac
  expect 0 'no-mistakes off' unknown
  case "$(cat "$TMP/stderr")" in *'unknown mode'*) ;; *) fail "unknown mode warning" ;; esac
  expect 0 'fm/' --branch-prefix unknown
  expect 0 'local-only off' extra
  [ ! -s "$TMP/stderr" ] || fail "unrelated token warned"
  expect 1 ''
  pass "unknown modes fall back, near-forge typos warn and missing arguments refuse"
}

test_defaults
test_annotations
test_forge
test_unknown_tokens
