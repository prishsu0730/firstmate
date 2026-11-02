#!/usr/bin/env bash
# Local merge-authority record validation without forge or runtime services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$ROOT/bin/fm-merge-authority-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
RECORD="$TMP/authority"
DEVICE=$(fm_pr_file_device "$TMP") || fail "fixture device"

write_record() {
  printf '%s\n' fm-merge-authority-v1 gitlab forge.example group/subgroup/repo 42 "$1" > "$RECORD"
  chmod 600 "$RECORD"
}

matches() {
  fm_merge_authority_record_matches "$RECORD" "$DEVICE" gitlab forge.example group/subgroup/repo 42
}

test_authorities() {
  local authority
  for authority in away attended yolo away-grant; do
    write_record "$authority"
    FM_MERGE_AUTHORITY=stale
    matches || fail "accepted authority: $authority"
    [ "$FM_MERGE_AUTHORITY" = "$authority" ] || fail "authority result: $authority"
  done
  for authority in '' external Away 'away '; do
    write_record "$authority"
    matches && fail "invalid authority accepted: [$authority]"
  done
  pass "current and legacy authorities accepted with exact spelling"
}

test_identity() {
  write_record attended
  fm_merge_authority_record_matches "$RECORD" "$DEVICE" github forge.example group/subgroup/repo 42 && fail "provider mismatch"
  fm_merge_authority_record_matches "$RECORD" "$DEVICE" gitlab other.example group/subgroup/repo 42 && fail "host mismatch"
  fm_merge_authority_record_matches "$RECORD" "$DEVICE" gitlab forge.example group/repo 42 && fail "path mismatch"
  fm_merge_authority_record_matches "$RECORD" "$DEVICE" gitlab forge.example group/subgroup/repo 43 && fail "number mismatch"
  fm_merge_authority_record_matches "$RECORD" wrong-device gitlab forge.example group/subgroup/repo 42 && fail "device mismatch"
  matches || fail "mismatches changed valid record"
  pass "every stored identity field and filesystem device must match"
}

test_structure() {
  local count
  : > "$RECORD"
  matches && fail "empty record accepted"
  for count in 1 2 3 4 5; do
    printf '%s\n' fm-merge-authority-v1 gitlab forge.example group/subgroup/repo 42 attended | head -n "$count" > "$RECORD"
    chmod 600 "$RECORD"
    matches && fail "truncated record accepted: $count lines"
  done
  write_record attended
  printf '\n' >> "$RECORD"
  matches && fail "extra blank line accepted"
  printf '%s\n' fm-merge-authority-v2 gitlab forge.example group/subgroup/repo 42 attended > "$RECORD"
  matches && fail "unknown version accepted"
  pass "truncated records, extra lines and unknown versions refuse"
}

test_file_safety() {
  write_record attended
  chmod 644 "$RECORD"
  matches && fail "public record accepted"
  chmod 600 "$RECORD"
  ln -s "$RECORD" "$TMP/symlink"
  fm_merge_authority_record_matches "$TMP/symlink" "$DEVICE" gitlab forge.example group/subgroup/repo 42 && fail "symlink accepted"
  ln "$RECORD" "$TMP/hardlink"
  matches && fail "multiply linked record accepted"
  fm_merge_authority_record_matches "$TMP/missing" "$DEVICE" gitlab forge.example group/subgroup/repo 42 && fail "missing record accepted"
  fm_merge_authority_record_matches "$TMP" "$DEVICE" gitlab forge.example group/subgroup/repo 42 && fail "directory accepted"
  pass "unsafe permissions, symlinks, hardlinks and non-files refuse"
}

test_authorities
test_identity
test_structure
test_file_safety
