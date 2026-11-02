#!/usr/bin/env bash
# Pure scope-map item and mapping parser validation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
# shellcheck source=bin/fm-scope-map-lib.sh
. "$ROOT/bin/fm-scope-map-lib.sh"

TMP=$(mktemp -d)
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$TMP"' EXIT
BRIEF="$TMP/brief"
MAP="$TMP/map"

test_items() {
  local got
  cat > "$BRIEF" <<'EOF'
## Captain's intent
Prose is ignored.
1. First item
   + Three spaces
    - Nested item
	- Tabbed item
```text
- Fenced item
```
2) Last intent
## Firstmate spec
~~~
* Fenced spec
~~~
* First spec
## Other
- Outside sections
EOF
  got=$(fm_scope_map_items "$BRIEF")
  [ "$got" = $'I1\tFirst item\nI2\tThree spaces\nI3\tLast intent\nS1\tFirst spec' ] || fail "item boundaries and numbering: $got"
  printf "## Firstmate spec\n- %0101d\n" 0 > "$BRIEF"
  got=$(fm_scope_map_items "$BRIEF")
  [ "${#got}" -eq 103 ] && [ "${got: -3}" = ... ] || fail "long item truncation"
  pass "items respect sections, indentation, fences, numbering, and truncation"
}

test_entries() {
  local got
  cat > "$MAP" <<'EOF'
# Map
- `I1`: old
S2 : bin/a.sh, abcdef0
+ I1: `bin/new.sh`
I3:
i4: ignored
Sx: ignored
I5 missing colon
EOF
  got=$(fm_scope_map_entries "$MAP")
  [ "$got" = $'I1\tbin/new.sh\nS2\tbin/a.sh, abcdef0\nI3\t' ] || fail "mapping normalization: $got"
  pass "mapping entries normalize bullets and backticks with last duplicate winning"
}

test_presence_and_output() {
  local got
  printf '# Scope map\n' > "$BRIEF"
  fm_scope_map_enforced "$BRIEF" || fail "exact heading"
  fm_scope_map_problems "$BRIEF" "$MAP" || fail "empty opted-in brief"
  printf ' # Scope map\n' > "$BRIEF"
  if fm_scope_map_enforced "$BRIEF"; then fail "indented heading accepted"; fi
  if fm_scope_map_enforced "$TMP/missing"; then fail "missing brief accepted"; fi
  got=$(fm_scope_map_items "$TMP/missing"; fm_scope_map_entries "$TMP/missing"; printf sentinel)
  [ "$got" = sentinel ] || fail "missing inputs emit output"
  got=$(fm_scope_map_path '/a path' task; printf sentinel)
  [ "$got" = $'/a path/task/scope-map.md\nsentinel' ] || fail "map path newline"
  pass "opt-in headings are exact and missing inputs and path output are stable"
}

test_items
test_entries
test_presence_and_output
