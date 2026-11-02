#!/usr/bin/env bash
# Pure remote session ancestry and Aqua birth classification.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$ROOT/bin/fm-remote-herdr-owner-lib.sh"

test_ssh_ancestry_matches() {
  local ancestry got rc
  for ancestry in \
    '42 sshd' \
    '42 /usr/sbin/sshd -D' \
    '42 sshd-session: user@notty' \
    '42 /usr/libexec/sshd-session user' \
    '42 herdr remote-client-bridge' \
    $'42 /opt/bin/herdr --flag\tremote-client-bridge --other' \
    $'42 bash -l\n7 /usr/sbin/sshd: user@pts/0\n1 launchd'; do
    got=$(printf '%s\n' "$ancestry" | fm_remote_herdr_ancestry_has_ssh_origin); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$got" ] || fail "SSH ancestry: [$ancestry]"
  done
  pass 'SSH executables, process titles, bridge arguments, and ancestors match silently'
}

test_ssh_ancestry_rejections() {
  local ancestry got rc
  for ancestry in '' '42 bash sshd' '42 agent remote-client-bridge' \
    '42 not-sshd' '42 sshd-session-helper' '42 SSHD' \
    '42 herdr remote-client-bridge-extra' '42 herdr --mode=remote-client-bridge' \
    '42 other-herdr remote-client-bridge' '42 /bin/bash /usr/sbin/sshd'; do
    got=$(printf '%s' "$ancestry" | fm_remote_herdr_ancestry_has_ssh_origin); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail "non-SSH ancestry: [$ancestry]"
  done
  pass 'incidental mentions, lookalikes, partial arguments, and empty ancestry are rejected'
}

test_aqua_birth_values() {
  local birth got rc
  for birth in launchd worker; do
    got=$(fm_remote_herdr_birth_is_aqua "$birth"); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$got" ] || fail "Aqua birth: [$birth]"
  done
  for birth in '' ssh unknown Launchd workers 'launchd ' $'worker\n' 'launchd|worker'; do
    got=$(fm_remote_herdr_birth_is_aqua "$birth"); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail "non-Aqua birth: [$birth]"
  done
  pass 'only exact launchd and worker birth values prove Aqua silently'
}

test_ssh_ancestry_matches
test_ssh_ancestry_rejections
test_aqua_birth_values
