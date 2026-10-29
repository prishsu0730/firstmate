#!/usr/bin/env bash
# Hold reason encoding and field-scoped decoding across supported formats.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-hold-reason-lib.sh
. "$ROOT/bin/fm-hold-reason-lib.sh"

test_encoding() {
  local got
  got=$(fm_hold_reason_encode 'hello') || fail "encoding failed"
  [ "$got" = 'fm-hold-v1:aGVsbG8=' ] || fail "unexpected encoding: [$got]"
  got=$(fm_hold_reason_encode '') || fail "empty encoding failed"
  [ "$got" = 'fm-hold-v1:' ] || fail "empty reason lost marker"
  got=$(fm_hold_reason_encode $'wait (review)\n再看') || fail "UTF-8 encoding failed"
  [[ "$got" != *'('* && "$got" != *')'* && "$got" != *$'\n'* ]] || fail "unsafe stored reason"
  got=$(printf '{"records":[{"hold_reason":"%s"}]}' "$got" |
    fm_hold_reason_decode_stream json |
    perl -MJSON::PP -0777 -ne 'binmode STDOUT, ":encoding(UTF-8)"; print decode_json($_)->{records}[0]{hold_reason}') || fail "round trip failed"
  [ "$got" = $'wait (review)\n再看' ] || fail "round trip changed reason: [$got]"
  pass "encoding handles empty reasons, punctuation, newlines and UTF-8"
}

test_markdown() {
  local got input expected
  input=$'- [ ] task (hold: fm-hold-v1:aGVsbG8=)\nplain fm-hold-v1:aGVsbG8=\n* task (hold: ordinary)\n- task (hold: fm-hold-v1:!!!)\n- task (hold: fm-hold-v1:/w==)'
  expected=$'- [ ] task (hold: "hello")\nplain fm-hold-v1:aGVsbG8=\n* task (hold: ordinary)\n- task (hold: fm-hold-v1:!!!)\n- task (hold: fm-hold-v1:/w==)'
  got=$(fm_hold_reason_decode_stream markdown <<<"$input") || fail "markdown decoding failed"
  [ "$got" = "$expected" ] || fail "markdown fields changed unexpectedly: [$got]"
  pass "markdown decodes only marked hold fields and preserves malformed payloads"
}

test_toon() {
  local got input expected
  input=$'tasks[1]{id,hold_reason,title}:\n  a,fm-hold-v1:aGVsbG8=,fm-hold-v1:aGVsbG8=\nother: fm-hold-v1:aGVsbG8=\ntask:\n  title: fm-hold-v1:aGVsbG8=\n  hold_reason: "fm-hold-v1:aGVsbG8="'
  expected=$'tasks[1]{id,hold_reason,title}:\n  a,"hello",fm-hold-v1:aGVsbG8=\nother: fm-hold-v1:aGVsbG8=\ntask:\n  title: fm-hold-v1:aGVsbG8=\n  hold_reason: "hello"'
  got=$(fm_hold_reason_decode_stream <<<"$input") || fail "TOON decoding failed"
  [ "$got" = "$expected" ] || fail "TOON fields changed unexpectedly: [$got]"
  pass "default TOON decoding targets tabular and single-task hold fields"
}

test_json() {
  local got input
  input='{"records":[{"hold_reason":"fm-hold-v1:aGVsbG8=","title":"fm-hold-v1:aGVsbG8="},{"hold_reason":"fm-hold-v1:!!!"},{"hold_reason":"fm-hold-v1:/w=="},{"hold_reason":"ordinary"},{"title":"no reason"},{"hold_reason":null},{"hold_reason":"fm-hold-v1:"},{"hold_reason":"fm-hold-v1:Zm0taG9sZC12MTphR1ZzYkc4PQ=="}],"extra":"preserved"}'
  got=$(fm_hold_reason_decode_stream json <<<"$input") || fail "JSON decoding failed"
  printf '%s' "$got" | perl -MJSON::PP -0777 -e '
    my $data = decode_json(<>);
    my $records = $data->{records};
    die "decoded reason" unless $records->[0]{hold_reason} eq "hello";
    die "title changed" unless $records->[0]{title} eq "fm-hold-v1:aGVsbG8=";
    die "malformed base64 changed" unless $records->[1]{hold_reason} eq "fm-hold-v1:!!!";
    die "invalid UTF-8 changed" unless $records->[2]{hold_reason} eq "fm-hold-v1:/w==";
    die "plain reason changed" unless $records->[3]{hold_reason} eq "ordinary";
    die "missing field added" if exists $records->[4]{hold_reason};
    die "null changed" if defined $records->[5]{hold_reason};
    die "empty reason" unless $records->[6]{hold_reason} eq "";
    die "decoded recursively" unless $records->[7]{hold_reason} eq "fm-hold-v1:aGVsbG8=";
    die "metadata changed" unless $data->{extra} eq "preserved";
    die "record count changed" unless @$records == 8;
  ' || fail "JSON fields changed unexpectedly: [$got]"
  pass "JSON preserves unrelated, missing, null and malformed fields and decodes once"
}

test_toon_scope_reset() {
  local got input expected
  input=$'tasks[1]{hold_reason,id}:\n  fm-hold-v1:aGVsbG8=,a\nmetadata:\n  hold_reason: fm-hold-v1:aGVsbG8=\ntasks[1]{id,title}:\n  b,fm-hold-v1:aGVsbG8=\ntask:\n  hold_reason: fm-hold-v1:aGVsbG8=\nsummary:\n  hold_reason: fm-hold-v1:aGVsbG8='
  expected=$'tasks[1]{hold_reason,id}:\n  "hello",a\nmetadata:\n  hold_reason: fm-hold-v1:aGVsbG8=\ntasks[1]{id,title}:\n  b,fm-hold-v1:aGVsbG8=\ntask:\n  hold_reason: "hello"\nsummary:\n  hold_reason: fm-hold-v1:aGVsbG8='
  got=$(fm_hold_reason_decode_stream toon <<<"$input") || fail "TOON scope decoding failed"
  [ "$got" = "$expected" ] || fail "TOON scope leaked or column order changed: [$got]"
  pass "TOON resets section scope and supports first-column reasons and tables without reasons"
}

test_encoding
test_markdown
test_toon
test_json
test_toon_scope_reset
