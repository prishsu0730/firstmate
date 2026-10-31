#!/usr/bin/env bash
# Pure project origin validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-project-origin-lib.sh
. "$ROOT/bin/fm-project-origin-lib.sh"

test_accepted() {
  local url
  for url in \
    'https://private.example/team/repo.git' 'http://localhost:8080/repo' \
    'ssh://git@alias:22/repo' 'git://192.0.2.1/repo' \
    'https://user:token@host/repo' 'https://[2001:db8::1]:443/repo' \
    'ssh://[fe80::1%25]/repo' 'git@alias:team/repo.git' \
    'host:path@revision' '[2001:db8::1]:repo' 'git@[::1]:repo' \
    '/absolute/repo.git' 'file:///absolute/repo.git'; do
    fm_project_origin_safe "$url" || fail "accepted origin rejected: $url"
  done
  pass "network, scp, IPv6, alias, and absolute local origins are accepted"
}

test_rejected() {
  local url
  for url in \
    '' '-repo' 'relative/repo' './repo' '../repo' 'ext::touch-file' \
    'ftp://host/repo' 'file://host/repo' '/repo/../other' '/repo/..' \
    'file:///../repo' 'file:///repo/..' 'https:///repo' 'https://-host/repo' \
    'https://host:/repo' 'https://host:abc/repo' 'https://host:22:33/repo' \
    'https://@host/repo' 'https://-user@host/repo' 'https://[host]/repo' \
    'https://[::1/repo' 'https://[::g]/repo' 'https://[::1]junk/repo' \
    'https://[::1]:/repo' 'https://[::1]:abc/repo' 'https://ho[st/repo' \
    'host:' 'host::repo' ':repo' '[host]:repo' '[::1]' \
    'https://host/a b' $'host:a\tb' $'host:a\nb' $'host:a\rb' $'host:a\001b'; do
    if fm_project_origin_safe "$url"; then fail "unsafe origin accepted: $url"; fi
  done
  if fm_project_origin_safe; then fail "missing argument accepted"; fi
  pass "unsafe transports, authorities, traversal, whitespace, and controls are rejected"
}

test_silent_output() {
  local got
  got=$(fm_project_origin_safe 'https://host/repo' 2>&1; printf sentinel)
  [ "$got" = sentinel ] || fail "accepted origin emitted output"
  got=$(fm_project_origin_safe 'relative/repo' 2>&1; printf sentinel)
  [ "$got" = sentinel ] || fail "rejected origin emitted output"
  pass "validation remains silent on success and failure"
}

test_accepted
test_rejected
test_silent_output
