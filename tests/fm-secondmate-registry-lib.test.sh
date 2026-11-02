#!/usr/bin/env bash
# Secondmate registry parsing without fleet state or remote services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
REG="$TMP/registry"
LOCAL='- mate.one - Notes (host: example; root: /code) (home: /homes/local; scope: writing (drafts); research; projects: alpha beta; added 2026-10-29)'
REMOTE='- mate-two - Remote notes (host: machine; root: /code; home: /homes/remote; scope: edits (review); tests; projects: ; added 2026-10-28)'

test_local_record() {
  secondmate_registry_parse_line "$LOCAL" || fail "local parse"
  [ "$SECONDMATE_REGISTRY_ID" = mate.one ] || fail "local id"
  [ "$SECONDMATE_REGISTRY_SUMMARY" = 'Notes (host: example; root: /code)' ] || fail "summary punctuation"
  [ "$SECONDMATE_REGISTRY_HOME" = /homes/local ] || fail "local home"
  [ "$SECONDMATE_REGISTRY_SCOPE" = 'writing (drafts); research' ] || fail "scope punctuation"
  [ "$SECONDMATE_REGISTRY_PROJECTS" = 'alpha beta' ] || fail "local projects"
  [ "$SECONDMATE_REGISTRY_ADDED" = 2026-10-29 ] || fail "local date"
  [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || fail "summary changed placement"
  [ -z "$SECONDMATE_REGISTRY_HOST$SECONDMATE_REGISTRY_ROOT" ] || fail "local remote fields"
  pass "local suffix parsing preserves natural language punctuation"
}

test_remote_record() {
  secondmate_registry_parse_line "$REMOTE  " || fail "remote parse"
  [ "$SECONDMATE_REGISTRY_ID" = mate-two ] || fail "remote id"
  [ "$SECONDMATE_REGISTRY_SUMMARY" = 'Remote notes' ] || fail "remote summary"
  [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || fail "remote flag"
  [ "$SECONDMATE_REGISTRY_HOST" = machine ] || fail "remote host"
  [ "$SECONDMATE_REGISTRY_ROOT" = /code ] || fail "remote root"
  [ "$SECONDMATE_REGISTRY_HOME" = /homes/remote ] || fail "remote home"
  [ "$SECONDMATE_REGISTRY_SCOPE" = 'edits (review); tests' ] || fail "remote scope"
  [ -z "$SECONDMATE_REGISTRY_PROJECTS" ] || fail "empty projects"
  [ "$SECONDMATE_REGISTRY_ADDED" = 2026-10-28 ] || fail "remote date"
  pass "remote records expose placement and allow empty project lists"
}

test_invalid_records() {
  local line
  for line in '' '# Registry' "${LOCAL/- mate.one/- bad\/id}" "${LOCAL/home: \/homes\/local/home:}" "${LOCAL/scope: writing (drafts); research/scope:}" "${LOCAL/2026-10-29/2026-1-29}" "$LOCAL extra" "${REMOTE/host: machine/host:}" "${REMOTE/root: \/code/root:}"; do
    secondmate_registry_parse_line "$line" && fail "malformed record accepted: $line"
  done
  secondmate_registry_parse_line "$REMOTE" || fail "reset setup"
  secondmate_registry_parse_line 'invalid' && fail "invalid reset input accepted"
  [ -z "$SECONDMATE_REGISTRY_ID$SECONDMATE_REGISTRY_HOST$SECONDMATE_REGISTRY_HOME" ] || fail "syntax failure retained fields"
  [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || fail "syntax failure retained remote flag"
  pass "malformed records refuse and syntax failures reset parsed fields"
}

test_lookup() {
  local key output
  printf '# Registry\n%s\n%s' "$LOCAL" "$REMOTE" > "$REG"
  secondmate_registry_line_for_id "$REG" mate-two || fail "unterminated final record"
  [ "$SECONDMATE_REGISTRY_LINE" = "$REMOTE" ] || fail "selected line"
  for key in host root home scope projects remote; do
    output=$(secondmate_registry_field "$REG" mate-two "$key") || fail "field $key"
    case "$key" in
      host) [ "$output" = machine ] || fail host ;;
      root) [ "$output" = /code ] || fail root ;;
      home) [ "$output" = /homes/remote ] || fail home ;;
      scope) [ "$output" = 'edits (review); tests' ] || fail scope ;;
      projects) [ -z "$output" ] || fail projects ;;
      remote) [ "$output" = 1 ] || fail remote ;;
    esac
  done
  secondmate_registry_field "$REG" mate-two unknown && fail "unknown field accepted"
  for key in mate 'mate/one' ''; do
    secondmate_registry_line_for_id "$REG" "$key" && fail "invalid or partial id accepted"
  done
  printf '\n%s\n' "$REMOTE" >> "$REG"
  secondmate_registry_line_for_id "$REG" mate-two && fail "duplicate id accepted"
  ln -s "$REG" "$TMP/link"
  secondmate_registry_line_for_id "$TMP/link" mate.one && fail "symlink registry accepted"
  secondmate_registry_line_for_id "$TMP/absent" mate.one && fail "missing registry accepted"
  pass "lookup selects exact unique ids and refuses unsafe registries and unknown fields"
}

test_local_record
test_remote_record
test_invalid_records
test_lookup
