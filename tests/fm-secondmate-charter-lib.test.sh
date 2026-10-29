#!/usr/bin/env bash
# Charter registry extraction and explicit caller overrides.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-secondmate-charter-lib.sh
. "$ROOT/bin/fm-secondmate-charter-lib.sh"

unset FM_SECONDMATE_CHARTER FM_SECONDMATE_SCOPE

test_normalize_registry_text() {
  local got
  got=$(printf '  Build; (review)\ttools  \n\n ship   fixes\n' | normalize_registry_text)
  [ "$got" = 'Build review tools ship fixes' ] || fail "registry text normalization: $got"
  got=$(printf ' ;()\t\n\n' | normalize_registry_text)
  [ -z "$got" ] || fail "punctuation-only text should normalize to empty"
  pass "registry text collapses whitespace and removes registry punctuation"
}

test_sections_and_defaults() {
  local got
  charter_fixture() { cat <<'BRIEF'
# Introduction
Ignore this section.
# Charter
Maintain (shared); tools.

## Details
Keep scripts readable.
# Routing scope
Internal; automation
and (tests).
# Other
Ignore this too.
BRIEF
  }
  got=$(brief_section_text <(charter_fixture) Charter)
  [ "$got" = $'Maintain (shared); tools.\n\n## Details\nKeep scripts readable.' ] \
    || fail "section extraction changed body or crossed the next top-level heading: $got"
  got=$(registry_summary_for_brief <(charter_fixture))
  [ "$got" = 'Maintain shared tools. ## Details Keep scripts readable.' ] \
    || fail "charter summary: $got"
  got=$(registry_scope_for_brief <(charter_fixture))
  [ "$got" = 'Internal automation and tests .' ] || fail "routing scope: $got"
  got=$(brief_section_text <(charter_fixture) Missing)
  [ -z "$got" ] || fail "missing section should be empty"
  pass "named sections retain nested headings and stop at the next top-level heading"
}

test_overrides_and_empty_fallback() {
  local got
  fallback_fixture() { printf '# Charter\nDefault charter\n# Routing scope\nDefault scope\n'; }
  got=$(FM_SECONDMATE_CHARTER=' Custom; (charter) ' registry_summary_for_brief /dev/null)
  [ "$got" = 'Custom charter' ] || fail "explicit charter override: $got"
  got=$(FM_SECONDMATE_SCOPE=$' Custom;\nscope ' registry_scope_for_brief /dev/null)
  [ "$got" = 'Custom scope' ] || fail "explicit scope override: $got"
  got=$(FM_SECONDMATE_CHARTER='' registry_summary_for_brief <(fallback_fixture))
  [ "$got" = 'Default charter' ] || fail "empty charter override should fall back: $got"
  got=$(FM_SECONDMATE_SCOPE='' registry_scope_for_brief <(fallback_fixture))
  [ "$got" = 'Default scope' ] || fail "empty scope override should fall back: $got"
  pass "nonempty overrides bypass the brief and empty overrides use its sections"
}

test_blank_normalized_overrides() {
  local got
  got=$(FM_SECONDMATE_CHARTER=$' \t\n' registry_summary_for_brief /dev/null; printf '|')
  [ "$got" = $'\n|' ] || fail "whitespace charter override should produce one empty line: $got"
  got=$(FM_SECONDMATE_SCOPE=' ;() ' registry_scope_for_brief /dev/null; printf '|')
  [ "$got" = $'\n|' ] || fail "punctuation scope override should produce one empty line: $got"
  got=$(FM_SECONDMATE_CHARTER=' ;() ' registry_summary_for_brief <(fallback_fixture))
  [ -z "$got" ] || fail "normalized-empty charter override should bypass fallback: $got"
  got=$(FM_SECONDMATE_SCOPE=$' \t\n' registry_scope_for_brief <(fallback_fixture))
  [ -z "$got" ] || fail "normalized-empty scope override should bypass fallback: $got"
  pass "nonempty overrides that normalize to blank bypass defaults and retain the output newline"
}

test_normalize_registry_text
test_sections_and_defaults
test_overrides_and_empty_fallback
test_blank_normalized_overrides
