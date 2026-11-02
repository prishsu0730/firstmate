#!/usr/bin/env bash
# Brief section boundaries, fenced headings, and Task-scoped lookups.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$ROOT/bin/fm-brief-heading-lib.sh"

assert_body() {
  local input=$1 heading=$2 expected=$3 got
  got=$(fm_brief_heading_body - "$heading" <<<"$input") || fail "body reader failed"
  [ "$got" = "$expected" ] || fail "body for [$heading]: [$got]"
}

test_section_boundaries() {
  assert_body $'# Task\nintro\n## Goal\nfirst\n### Detail\nnested\n## Next\nother' \
    '## Goal' $'first\n### Detail\nnested'
  assert_body $'## Goal\nfirst\n# End\nother' '## Goal' first
  assert_body $'## Goal\nfirst\n   ## Next\nother' '## Goal' first
  assert_body $'## Goal\nfirst\n##not-a-heading\nlast' '## Goal' $'first\n##not-a-heading\nlast'
  assert_body $'## Goal extra\nwrong' '## Goal' ''
  fm_brief_heading_present - '## Goal' <<<'## Goal' || fail "empty section exists"
  if fm_brief_heading_present - '## Goal' <<<'## Goal extra'; then
    fail "heading must match exactly"
  fi
  pass "exact headings retain nested sections and stop at peers or parents"
}

test_fenced_headings() {
  local input
  input=$'```markdown\n## Goal\nignored\n```\n## Goal\nkept\n~~~\n## Fake\n~~~\nlast\n## End'
  assert_body "$input" '## Goal' $'kept\n~~~\n## Fake\n~~~\nlast'
  if fm_brief_heading_present - '## Fake' <<<"$input"; then
    fail "fenced heading must not exist"
  fi
  input=$'## Goal\n   ````text\n## Hidden\n```\n## Still hidden\n~~~~\n## Also hidden\n```` trailing\n## Hidden too\n   `````\nlast\n## End'
  assert_body "$input" '## Goal' $'   ````text\n## Hidden\n```\n## Still hidden\n~~~~\n## Also hidden\n```` trailing\n## Hidden too\n   `````\nlast'
  pass "fences hide headings and close only with matching sufficient markers"
}

test_task_scope() {
  local input got
  input=$'## Goal\noutside\n# Task\n## Goal\ninside\n# Other\n## Later\noutside'
  got=$(fm_brief_task_heading_body - '## Goal' <<<"$input") || fail "task body reader failed"
  [ "$got" = inside ] || fail "task body escaped scope: [$got]"
  fm_brief_task_heading_present - '## Goal' <<<"$input" || fail "task heading missing"
  if fm_brief_task_heading_present - '## Later' <<<"$input"; then
    fail "heading outside Task must not exist in Task"
  fi
  got=$(fm_brief_task_heading_body - '## Goal' <<<'## Goal') || fail "missing Task body failed"
  [ -z "$got" ] || fail "missing Task must have empty body"
  if fm_brief_task_heading_present - '## Goal' <<<'## Goal'; then
    fail "missing Task must not expose outside headings"
  fi
  pass "Task helpers restrict body and presence queries to the Task section"
}

test_missing_input() {
  local input got
  for input in /dev/null/missing /dev/null; do
    got=$(fm_brief_heading_body "$input" '## Goal') || fail "missing heading body failed"
    [ -z "$got" ] || fail "missing heading returned content: [$got]"
    if fm_brief_heading_present "$input" '## Goal'; then
      fail "missing heading must not exist"
    fi
    got=$(fm_brief_task_heading_body "$input" '## Goal') || fail "missing Task body failed"
    [ -z "$got" ] || fail "missing Task returned content: [$got]"
    if fm_brief_task_heading_present "$input" '## Goal'; then
      fail "missing Task heading must not exist"
    fi
  done
  got=$(fm_brief_heading_body - '## Goal' </dev/null) || fail "empty stdin body failed"
  [ -z "$got" ] || fail "empty stdin returned content: [$got]"
  if fm_brief_heading_present - '## Goal' </dev/null; then
    fail "empty stdin heading must not exist"
  fi
  pass "missing and nonregular files and empty stdin have empty bodies and absent headings"
}

test_repeated_and_indented_headings() {
  assert_body $'## Goal\nfirst\n## Goal\nsecond' '## Goal' first
  assert_body $'## Goal\nfirst\n    ## Next\nstill inside\n## End\noutside' \
    '## Goal' $'first\n    ## Next\nstill inside'
  assert_body $'    ## Goal\nindented only' '## Goal' ''
  if fm_brief_heading_present - '## Goal' <<<'    ## Goal'; then
    fail "indented target must not match exact heading"
  fi
  pass "first repeated heading wins and four-space headings stay body text"
}

test_short_fence_markers() {
  local marker input
  for marker in '`' '``' '~' '~~'; do
    input=$(printf '## Goal\nkept\n%s\n## Next\noutside' "$marker")
    assert_body "$input" '## Goal' "$(printf 'kept\n%s' "$marker")"
    fm_brief_heading_present - '## Next' <<<"$input" || fail "short marker hid heading: [$marker]"
  done
  pass "one and two fence markers remain body text and do not hide headings"
}

test_unclosed_fences() {
  local marker input
  for marker in '```' '~~~'; do
    input=$(printf '## Goal\nkept\n%s text\n## Hidden\nstill fenced' "$marker")
    assert_body "$input" '## Goal' "$(printf 'kept\n%s text\n## Hidden\nstill fenced' "$marker")"
    if fm_brief_heading_present - '## Hidden' <<<"$input"; then
      fail "unclosed fence exposed heading: [$marker]"
    fi
    input=$(printf '%s text\n## Goal\nhidden through EOF' "$marker")
    assert_body "$input" '## Goal' ''
    if fm_brief_heading_present - '## Goal' <<<"$input"; then
      fail "heading inside unclosed initial fence must be absent: [$marker]"
    fi
  done
  pass "unclosed backtick and tilde fences hide headings through EOF and preserve body text"
}

test_fence_closing_whitespace() {
  local marker input
  for marker in '```' '~~~'; do
    input=$(printf '## Goal\n%s text\n## Hidden\n  %s \t \nkept\n## Next\noutside' "$marker" "$marker")
    assert_body "$input" '## Goal' "$(printf '%s text\n## Hidden\n  %s \t \nkept' "$marker" "$marker")"
    fm_brief_heading_present - '## Next' <<<"$input" || fail "whitespace closer hid next heading: [$marker]"
    if fm_brief_heading_present - '## Hidden' <<<"$input"; then
      fail "whitespace closer exposed fenced heading: [$marker]"
    fi
  done
  pass "indented fence closers accept trailing spaces and tabs and restore heading parsing"
}

test_section_boundaries
test_fenced_headings
test_task_scope
test_missing_input
test_repeated_and_indented_headings
test_short_fence_markers
test_unclosed_fences
test_fence_closing_whitespace
