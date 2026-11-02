#!/usr/bin/env bash
# Quota helper validation without invoking quota-axi or network services.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$ROOT/bin/fm-quota-axi-lib.sh"

test_versions() {
  local version got rc
  for version in '0.1.51' 'quota-axi 0.1.52' '0.2.0' '1.0.0'; do
    got=$(fm_quota_axi_version_compatible "$version" 2>&1); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$got" ] || fail "compatible version: $version"
  done
  for version in '' 'development' '0.1' '0.1.50' '0.0.99'; do
    got=$(fm_quota_axi_version_compatible "$version" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail "incompatible version: $version"
  done
  pass 'version floor accepts current and newer releases and refuses missing or older versions silently'
}

test_provider_mapping() {
  local harness expected got rc
  while read -r harness expected; do
    got=$(fm_quota_single_provider_for_harness "$harness"; printf '|')
    [ "$got" = "$expected"$'\n|' ] || fail "single provider: $harness"
    got=$(fm_quota_provider_for_harness "$harness")
    [ "$got" = "$expected" ] || fail "provider: $harness"
  done <<'ROWS'
claude claude
codex codex
grok grok
kimi kimi
cursor cursor
muse meta
ROWS
  for harness in pi pi-signed; do
    [ "$(fm_quota_provider_for_harness "$harness")" = pi ] || fail 'pi provider'
  done
  [ "$(fm_quota_provider_for_harness opencode)" = codex ] || fail 'opencode provider'
  [ "$(fm_quota_single_provider_for_harness agy)" = agy ] || fail 'agy single provider'
  [ "$(fm_quota_provider_for_harness omp openai-codex/model)" = codex ] || fail 'omp codex provider'
  [ "$(fm_quota_provider_for_harness omp claude-bridge/model)" = claude ] || fail 'omp claude provider'
  for harness in unknown '' pi omp; do
    got=$(fm_quota_single_provider_for_harness "$harness" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'unknown single provider'
  done
  for harness in unknown '' agy omp; do
    got=$(fm_quota_provider_for_harness "$harness" unsupported/model 2>&1); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$got" ] || fail 'unsupported provider mapping'
  done
  pass 'provider mappings preserve harness distinctions and refuse unsupported models silently'
}

test_json_validation() {
  local payload got rc
  for payload in '{"schemaVersion":5,"providers":[]}' '{"schemaVersion":6,"providers":[]}'; do
    got=$(printf '%s\n' "$payload" | fm_quota_json_valid 2>&1); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$got" ] || fail 'supported empty snapshot'
  done
  for payload in '' 'not json' '{}' '[]' 'null' \
    '{"schemaVersion":4,"providers":[]}' \
    '{"schemaVersion":6,"providers":{}}' \
    '{"schemaVersion":5,"providers":[]} {"schemaVersion":5,"providers":[]}'; do
    got=$(printf '%s\n' "$payload" | fm_quota_json_valid 2>&1); rc=$?
    [ "$rc" -ne 0 ] && [ -z "$got" ] || fail 'invalid snapshot refuses silently'
  done
  pass 'JSON validation accepts supported schemas and refuses malformed, unsupported, or multiple documents'
}

test_populated_snapshots() {
  local base filter payload got rc
  base='{"schemaVersion":6,"providers":[{"provider":"codex","accountKey":"codex-home","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"account","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}]}'
  for filter in '.' '.schemaVersion = 5 | del(.providers[0].accountKey)' \
    '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 0' \
    '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 100' \
    '.providers += [(.providers[0] | .accountKey = "other")]' \
    '.providers[0].quotaSemantics = {"status":"unknown","effectiveAvailability":[{"scope":"account","status":"unknown"}]}'; do
    payload=$(printf '%s\n' "$base" | jq -c "$filter") || fail 'valid fixture construction'
    got=$(printf '%s\n' "$payload" | fm_quota_json_valid 2>&1); rc=$?
    [ "$rc" -eq 0 ] && [ -z "$got" ] || fail "valid populated snapshot: $filter"
  done
  for filter in '.providers += [.providers[0]]' \
    '.schemaVersion = 5 | .providers += [(.providers[0] | .accountKey = "other")]' \
    'del(.providers[0].accountKey)' '.providers[0].accountKey = ""' \
    '.providers[0].accountKey = "two accounts"' '.providers[0].provider = "Codex"' \
    '.providers[0].quotaSemantics.effectiveAvailability = []' \
    '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = -1' \
    '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 101' \
    '.providers[0].quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = "50"' \
    '.providers[0].quotaSemantics.effectiveAvailability[0].scope = " account"' \
    '.providers[0].quotaSemantics.effectiveAvailability[0].runway.status = "invalid"' \
    '.providers[0].quotaSemantics.status = "unknown"'; do
    payload=$(printf '%s\n' "$base" | jq -c "$filter") || fail 'invalid fixture construction'
    got=$(printf '%s\n' "$payload" | fm_quota_json_valid 2>&1); rc=$?
    [ "$rc" -ne 0 ] && [ -z "$got" ] || fail "invalid populated snapshot: $filter"
  done
  pass 'populated snapshots enforce account uniqueness, provider IDs, availability bounds, and runway semantics'
}

test_versions
test_provider_mapping
test_json_validation
test_populated_snapshots
