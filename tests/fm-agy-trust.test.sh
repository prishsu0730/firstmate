#!/usr/bin/env bash
# Workspace trust registration using the current linked worktree and a private store.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
mkdir -p "$TMP/home/.gemini/antigravity-cli" "$TMP/plain"
STORE="$TMP/home/.gemini/antigravity-cli/settings.json"
trust_workspace() { env HOME="$TMP/home" bash "$ROOT/bin/fm-agy-trust.sh" "$@" > "$TMP/stdout" 2> "$TMP/stderr"; }
expect_status() {
  local expected=$1 rc
  shift
  trust_workspace "$@"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "expected $expected, got $rc: $(cat "$TMP/stderr")"
}

test_validation() {
  expect_status 2
  expect_status 2 "$ROOT"
  expect_status 2 "$ROOT" "$ROOT" extra
  expect_status 1 "$TMP/missing" "$ROOT"
  expect_status 1 "$ROOT" "$TMP/missing"
  expect_status 1 "$TMP/home" "$ROOT"
  expect_status 1 "$TMP/plain" "$ROOT"
  expect_status 1 "$ROOT/tests" "$ROOT"
  [ ! -e "$STORE" ] || fail 'refusals created settings'
  pass 'invalid arguments, inaccessible paths, home, non-repositories and subdirectories are refused'
}

test_registration() {
  local git_dir common_dir
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir)
  common_dir=$(git -C "$ROOT" rev-parse --git-common-dir)
  common_dir=$(cd "$ROOT" && cd "$common_dir" && pwd -P)
  if [ "$git_dir" = "$common_dir" ]; then
    expect_status 1 "$ROOT" "$ROOT"
    pass 'primary checkout is refused (registration requires a linked worktree)'
    return
  fi
  printf '{"theme":"dark","trustedWorkspaces":["/previous"]}\n' > "$STORE"
  expect_status 0 "$ROOT" "$ROOT"
  node - "$STORE" "$ROOT" <<'NODE' || fail 'registration contents'
const fs = require('fs');
const [file, root] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
if (value.theme !== 'dark' || !value.trustedWorkspaces.includes('/previous') ||
    !value.trustedWorkspaces.includes(root) || (fs.statSync(file).mode & 0o777) !== 0o600) process.exit(1);
NODE
  local before
  before=$(cat "$STORE")
  expect_status 0 "$ROOT" "$ROOT"
  [ "$(cat "$STORE")" = "$before" ] || fail 'repeat registration changed store'
  case "$(cat "$TMP/stdout")" in trusted:*) ;; *) fail 'missing confirmation' ;; esac
  pass 'registration preserves unrelated settings and trust, uses private permissions and repeats unchanged'
}

test_invalid_store() {
  local value before git_dir common_dir
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir)
  common_dir=$(git -C "$ROOT" rev-parse --git-common-dir)
  common_dir=$(cd "$ROOT" && cd "$common_dir" && pwd -P)
  [ "$git_dir" != "$common_dir" ] || return 0
  for value in '{bad' '[]' 'null' '{"trustedWorkspaces":"wrong"}'; do
    printf '%s\n' "$value" > "$STORE"
    before=$(cat "$STORE")
    expect_status 1 "$ROOT" "$ROOT"
    [ "$(cat "$STORE")" = "$before" ] || fail 'invalid store was overwritten'
  done
  [ "$(find "$(dirname "$STORE")" -name '.settings.json.fm-trust.*' | wc -l | tr -d ' ')" -eq 0 ] || fail 'temporary settings leaked'
  pass 'malformed JSON and invalid settings shapes are preserved without temporary-file leaks'
}

test_validation
test_registration
test_invalid_store
