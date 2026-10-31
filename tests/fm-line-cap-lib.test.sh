#!/usr/bin/env bash
# Per-line cap boundaries and matching variable and stdout interfaces.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-line-cap-lib.sh
. "$ROOT/bin/fm-line-cap-lib.sh"

assert_cap() {
  local line=$1 max=$2 expected=$3 got
  fm_cap_line_var "$line" "$max"
  [ "$FM_LINE_CAP_LINE" = "$expected" ] || fail "variable cap at [$max]: [$FM_LINE_CAP_LINE]"
  got=$(fm_cap_line "$line" "$max")
  [ "$got" = "$expected" ] || fail "stdout cap at [$max]: [$got]"
}

test_unchanged_lines() {
  assert_cap '' 20 ''
  assert_cap short 20 short
  assert_cap '12345678901234567890' 20 '12345678901234567890'
  assert_cap ' [truncated]' 12 ' [truncated]'
  assert_cap 'a b/*?[x]' 20 'a b/*?[x]'
  pass "empty, short, exact-length, and literal lines stay unchanged"
}

test_truncated_lines() {
  assert_cap '123456789012345678901' 20 '12345678 [truncated]'
  assert_cap '1234567890123' 12 ' [truncated]'
  assert_cap abcdef 3 ' [truncated]'
  assert_cap abc 0 ' [truncated]'
  assert_cap '' 0 ''
  assert_cap short 20 short
  pass "long lines retain their prefix and small caps retain the whole suffix"
}

test_default_and_stdout() {
  local line='' i got
  for ((i = 0; i < 220; i++)); do line+=x; done
  fm_cap_line_var "$line"
  [ "$FM_LINE_CAP_LINE" = "$line" ] || fail "default preserves 220 characters"
  fm_cap_line_var "${line}x"
  [ "$FM_LINE_CAP_LINE" = "${line:0:208} [truncated]" ] || fail "default truncates at 220 characters"
  got=$(fm_cap_line "${line}x" '')
  [ "$got" = "$FM_LINE_CAP_LINE" ] || fail "empty cap uses default"
  got=$(fm_cap_line short 20; printf sentinel)
  [ "$got" = $'short\nsentinel' ] || fail "stdout ends with one newline"
  pass "default and empty caps use 220 characters and stdout includes a newline"
}

test_multibyte_lines() {
  local LC_ALL=en_US.UTF-8
  export LC_ALL
  assert_cap '台灣中文' 4 '台灣中文'
  assert_cap '台灣中文測試台灣中文測試台' 13 '台灣中文測試台灣中文測試台'
  assert_cap '台灣中文測試台灣中文測試台灣' 13 '台 [truncated]'
  assert_cap '😀台灣中文測試台灣中文測試台' 14 '😀台灣中文測試台灣中文測試台'
  assert_cap '😀台灣中文測試台灣中文測試台灣' 14 '😀台 [truncated]'
  assert_cap '台灣中文' 3 ' [truncated]'
  pass "UTF-8 caps count characters and preserve complete Chinese and emoji prefixes"
}

test_variable_reuse_and_silence() {
  local got
  FM_LINE_CAP_LINE=stale
  fm_cap_line_var '123456789012345678901' 20
  [ "$FM_LINE_CAP_LINE" = '12345678 [truncated]' ] || fail "variable receives truncated result"
  fm_cap_line_var short 20
  [ "$FM_LINE_CAP_LINE" = short ] || fail "short result replaces truncated result"
  fm_cap_line_var '' 20
  [ "$FM_LINE_CAP_LINE" = '' ] || fail "empty result clears previous value"
  got=$(fm_cap_line_var '123456789012345678901' 20; printf sentinel)
  [ "$got" = sentinel ] || fail "truncated variable interface is silent"
  got=$(fm_cap_line_var '' 20; printf sentinel)
  [ "$got" = sentinel ] || fail "empty variable interface is silent"
  pass "variable calls replace and clear previous results without stdout"
}

test_whitespace_and_trailing_newlines() {
  local line=$' \tvalue \n\n' got
  fm_cap_line_var "$line" 20
  [ "$FM_LINE_CAP_LINE" = "$line" ] || fail "variable preserves whitespace and trailing newlines"
  got=$(fm_cap_line "$line" 20; printf sentinel)
  [ "$got" = "${line}"$'\nsentinel' ] || fail "stdout preserves input newlines and adds exactly one newline"
  assert_cap $' \t12345678901234567890' 20 $' \t123456 [truncated]'
  pass "whitespace and trailing newlines survive unchanged and truncated calls"
}

test_custom_defaults_and_suffixes() {
  local FM_LINE_CAP_DEFAULT=8 FM_LINE_CAP_SUFFIX='...'
  local got
  fm_cap_line_var '123456789'
  [ "$FM_LINE_CAP_LINE" = '12345...' ] || fail "custom default and suffix determine retained prefix"
  got=$(fm_cap_line '123456789' '')
  [ "$got" = '12345...' ] || fail "empty cap uses custom default"
  assert_cap abcdef 2 '...'
  FM_LINE_CAP_SUFFIX=''
  assert_cap abcdef 3 abc
  assert_cap abcdef 0 ''
  pass "custom defaults and suffixes govern truncation, including empty suffixes"
}

test_multibyte_suffix_and_embedded_newlines() {
  local LC_ALL=en_US.UTF-8 FM_LINE_CAP_SUFFIX='…台'
  export LC_ALL
  assert_cap 'abcdef' 4 'ab…台'
  assert_cap 'abcdef' 2 '…台'
  assert_cap 'abcdef' 1 '…台'
  assert_cap $'a\nb\nc' 4 $'a\n…台'
  assert_cap $'a\nb' 3 $'a\nb'
  pass "multibyte suffixes and embedded newlines count as characters"
}

test_stdout_updates_variable() {
  local got
  FM_LINE_CAP_LINE=stale
  got=$({ fm_cap_line '123456789012345678901' 20 >/dev/null; printf '%s' "$FM_LINE_CAP_LINE"; })
  [ "$got" = '12345678 [truncated]' ] || fail "stdout call stores truncated result"
  got=$({ fm_cap_line short 20 >/dev/null; printf '%s' "$FM_LINE_CAP_LINE"; })
  [ "$got" = short ] || fail "stdout call replaces stale result with short line"
  got=$({ fm_cap_line '' 20 >/dev/null; printf '<%s>' "$FM_LINE_CAP_LINE"; })
  [ "$got" = '<>' ] || fail "stdout call clears stale result for empty input"
  pass "direct stdout calls also replace and clear the result variable"
}

test_literal_format_characters() {
  local FM_LINE_CAP_SUFFIX='%s\n' got
  assert_cap '%s\n\t%%' 20 '%s\n\t%%'
  assert_cap 'abcdefghij' 7 'abc%s\n'
  got=$(fm_cap_line 'abcdefghij' 7; printf sentinel)
  [ "$got" = 'abc%s\n'$'\nsentinel' ] || fail "stdout treats suffix format characters literally"
  pass "percent signs and backslash escapes remain literal in lines and suffixes"
}

test_strict_shell_callers() {
  local got status
  got=$(
    set -euo pipefail
    fm_cap_line_var short 20
    [ "$FM_LINE_CAP_LINE" = short ]
    fm_cap_line_var '123456789012345678901' 20
    [ "$FM_LINE_CAP_LINE" = '12345678 [truncated]' ]
    fm_cap_line_var abc 0
    [ "$FM_LINE_CAP_LINE" = ' [truncated]' ]
    fm_cap_line '' 0
    fm_cap_line abc 0
    printf sentinel
  )
  status=$?
  [ "$status" -eq 0 ] || fail "valid calls succeed under errexit, nounset, and pipefail"
  [ "$got" = $'\n [truncated]\nsentinel' ] || fail "strict-shell stdout preserves empty and small-cap results"
  pass "unchanged, truncated, empty, and small-cap calls succeed under strict shell options"
}

test_byte_locale() {
  local LC_ALL=C FM_LINE_CAP_SUFFIX='.'
  export LC_ALL
  assert_cap $'\345\217\260\347\201\243' 6 $'\345\217\260\347\201\243'
  assert_cap $'\345\217\260\347\201\243' 4 $'\345\217\260.'
  assert_cap $'\345\217\260\347\201\243' 3 $'\345\217.'
  pass "C locale counts bytes and applies the suffix at byte boundaries"
}

test_suffix_trailing_newlines() {
  local FM_LINE_CAP_SUFFIX=$'!\n\n' got
  fm_cap_line_var abcdef 5
  [ "$FM_LINE_CAP_LINE" = $'ab!\n\n' ] || fail "variable preserves suffix trailing newlines"
  got=$(fm_cap_line abcdef 5; printf sentinel)
  [ "$got" = $'ab!\n\n\nsentinel' ] || fail "stdout adds one newline after suffix trailing newlines"
  fm_cap_line_var abcdef 1
  [ "$FM_LINE_CAP_LINE" = "$FM_LINE_CAP_SUFFIX" ] || fail "small cap preserves entire multiline suffix"
  pass "suffix trailing newlines survive variable and stdout interfaces"
}

test_combining_characters() {
  local LC_ALL=en_US.UTF-8 FM_LINE_CAP_SUFFIX='.'
  export LC_ALL
  assert_cap $'e\314\201x' 3 $'e\314\201x'
  assert_cap $'e\314\201xy' 3 $'e\314\201.'
  assert_cap $'e\314\201x' 2 'e.'
  pass "UTF-8 caps count combining marks separately from their base characters"
}

test_zero_default() {
  local FM_LINE_CAP_DEFAULT=0 FM_LINE_CAP_SUFFIX='.' got
  fm_cap_line_var ''
  [ "$FM_LINE_CAP_LINE" = '' ] || fail "zero default preserves empty input"
  fm_cap_line_var abc
  [ "$FM_LINE_CAP_LINE" = '.' ] || fail "zero default truncates nonempty input"
  got=$(fm_cap_line abc '')
  [ "$got" = '.' ] || fail "empty cap uses zero default"
  assert_cap abc 3 abc
  pass "zero default applies to omitted and empty caps while explicit caps override it"
}

test_unchanged_lines
test_truncated_lines
test_default_and_stdout
test_multibyte_lines
test_variable_reuse_and_silence
test_whitespace_and_trailing_newlines
test_custom_defaults_and_suffixes
test_multibyte_suffix_and_embedded_newlines
test_stdout_updates_variable
test_literal_format_characters
test_strict_shell_callers
test_byte_locale
test_suffix_trailing_newlines
test_combining_characters
test_zero_default
