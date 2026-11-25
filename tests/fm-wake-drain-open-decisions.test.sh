#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_unchanged_decision_is_summarized_after_first_presentation() {
  local dir state out
  dir=$(make_case unchanged)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed"
  grep -F 'pick REST or RPC' "$out" >/dev/null || fail "first drain did not print the decision in full"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  if grep -F 'pick REST or RPC' "$out" >/dev/null; then
    fail "an unchanged decision was re-printed in full: $(cat "$out")"
  fi
  grep -F 'OPEN DECISIONS: 1 unchanged' "$out" | grep -F -- '--all-open-decisions' >/dev/null \
    || fail "second drain is missing the unchanged summary line: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --all-open-decisions > "$out" || fail "full listing failed"
  grep -F 'pick REST or RPC' "$out" >/dev/null || fail "--all-open-decisions did not list the decision in full"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after the listing failed"
  grep -F 'OPEN DECISIONS: 1 unchanged' "$out" >/dev/null || fail "the read-only listing disturbed the presented record"

  FM_DRAIN_FULL_OPEN_DECISIONS=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "full-mode drain failed"
  grep -F 'pick REST or RPC' "$out" >/dev/null || fail "full mode (session start) did not print the decision in full"

  printf 'needs-decision [key=api-shape]: pick REST, RPC, or GraphQL\n' >> "$state/task1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after a change failed"
  grep -F 'pick REST, RPC, or GraphQL' "$out" >/dev/null || fail "a changed decision did not print in full again: $(cat "$out")"

  printf 'needs-decision [key=second]: brand new\n' > "$state/task2.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after a new decision failed"
  grep -F 'brand new' "$out" >/dev/null || fail "a new decision did not print in full"
  grep -F 'OPEN DECISIONS: 1 unchanged' "$out" >/dev/null || fail "the older decision was not summarized beside the new one"
  pass "an unchanged open decision prints once, then as a count; new or changed ones print in full"
}

test_aged_open_decision_returns_on_every_drain() {
  local dir state out now mode
  for mode in empty ordinary; do
    dir=$(make_case "aged-$mode")
    state="$dir/state"
    out="$dir/drain.out"
    now=$(date +%s)
    printf 'needs-decision [key=old-call] [at=%s]: pick the rollout plan\n' "$((now - 18000))" > "$state/task1.status"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "initial drain failed"
    if [ "$mode" = ordinary ]; then
      printf 'working: continuing\n' > "$state/other.status"
      append_wake "$state" signal other.status 'working: continuing' || fail "queue failed"
    fi
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "aged drain failed"
    grep -F 'pick the rollout plan' "$out" | grep -F '5h' >/dev/null || fail "$mode drain hid aged decision"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "repeat drain failed"
    if grep -F 'pick the rollout plan' "$out" >/dev/null; then fail "immediate reprint"; fi
    mkdir "$dir/clock"
    cat > "$dir/clock/date" <<EOF
#!/usr/bin/env bash
if [ "\$1" = +%s ]; then echo $((now + 14460)); else exec $(command -v date) "\$@"; fi
EOF
    chmod +x "$dir/clock/date"
    PATH="$dir/clock:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "later drain failed"
    grep -F 'pick the rollout plan' "$out" | grep -F '9h' >/dev/null || fail "decision did not return after interval"
  done
  pass "aged decisions return on ordinary and empty drains, once per interval"
}

test_aged_decisions_rotate_and_new_decisions_go_first() {
  local dir state out now i note
  dir=$(make_case aged-rotation)
  state="$dir/state"
  out="$dir/drain.out"
  now=$(date +%s)
  note=$(printf '%0200d' 0)
  for i in $(seq 1 20); do
    printf 'needs-decision [key=call] [at=%s]: choice-%02d %s\n' "$((now - 18000))" "$i" "$note" > "$state/task$i.status"
  done
  FM_DRAIN_FULL_OPEN_DECISIONS=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "seed failed"
  printf 'needs-decision: brand new choice\n' > "$state/zz-new.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first rotation failed"
  grep -F 'brand new choice' "$out" >/dev/null || fail "aged decisions crowded out new decision"
  for i in $(seq 1 20); do
    if ! grep -F "choice-$(printf '%02d' "$i")" "$out" >/dev/null; then
      printf '%s\n' "$i" >> "$dir/remaining"
    fi
  done
  [ -s "$dir/remaining" ] || fail "fixture did not exceed budget"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second rotation failed"
  while read -r i; do
    grep -F "choice-$(printf '%02d' "$i")" "$out" >/dev/null || fail "omitted decision starved"
  done < "$dir/remaining"
  pass "aged decisions rotate within the budget and new decisions print first"
}

test_aged_open_decision_age_limit_is_configurable() {
  local dir state out now
  dir=$(make_case aged-limit)
  state="$dir/state"
  out="$dir/drain.out"
  now=$(date +%s)
  printf 'needs-decision [key=mid-call] [at=%s]: pick the logo\n' "$((now - 1800))" > "$state/task1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed"
  append_wake "$state" heartbeat heartbeat "heartbeat" || fail "queueing the heartbeat failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "default-limit heartbeat drain failed"
  if grep -F 'pick the logo' "$out" >/dev/null; then
    fail "a 30-minute-old decision came back under the 4-hour default: $(cat "$out")"
  fi

  FM_OPEN_DECISION_RESURFACE_AFTER=600 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "short-limit heartbeat drain failed"
  grep -F 'pick the logo' "$out" | grep -F '30m' >/dev/null \
    || fail "a 10-minute limit did not bring the 30-minute-old decision back with its age: $(cat "$out")"
  pass "the age limit defaults to four hours and FM_OPEN_DECISION_RESURFACE_AFTER changes it"
}

test_full_listing_is_read_only_and_bounded() {
  local dir state out cursor presented cursor_before presented_before probe bytes
  dir=$(make_case readonly-listing)
  state="$dir/state"
  out="$dir/drain.out"
  cursor="$state/.task1.open-decisions-cursor"
  presented="$state/.open-decisions-presented"
  cursor_before="$dir/cursor.before"
  presented_before="$dir/presented.before"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "initial drain failed"
  [ -f "$cursor" ] || fail "initial drain did not create its decision cursor"
  [ -f "$presented" ] || fail "initial drain did not create its presented record"
  cp "$cursor" "$cursor_before"
  cp "$presented" "$presented_before"

  printf 'needs-decision [key=api-shape]: choose a REST or RPC endpoint\n' >> "$state/task1.status"
  probe="$dir/read-probe"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_STATE_OVERRIDE="$state" "$DRAIN" --all-open-decisions > "$out" || fail "full listing failed"
  grep -F 'choose a REST or RPC endpoint' "$out" >/dev/null || fail "full listing did not fold the appended decision"
  cmp -s "$cursor_before" "$cursor" || fail "full listing changed the durable decision cursor"
  cmp -s "$presented_before" "$presented" || fail "full listing changed the presented record"
  bytes=$(awk -F '\t' 'END { print $2 + 0 }' "$probe")
  [ "$bytes" -eq "$(printf 'needs-decision [key=api-shape]: choose a REST or RPC endpoint\n' | wc -c | tr -d ' ')" ] \
    || fail "full listing read $bytes bytes instead of only the appended span"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after the listing failed"
  grep -F 'choose a REST or RPC endpoint' "$out" >/dev/null || fail "drain after listing did not present the appended decision"
}

test_full_listing_exceeds_ordinary_byte_cap() {
  local dir state out i bytes
  dir=$(make_case full-listing-cap)
  state="$dir/state"
  out="$dir/drain.out"
  for i in $(seq 1 40); do
    printf 'needs-decision [key=api-shape]: decision number %02d with a deliberately descriptive explanation 中文\n' "$i" > "$state/task$i.status"
  done

  LC_ALL="${FM_TEST_MULTIBYTE_LOCALE:-${LC_ALL:-C.UTF-8}}" FM_STATE_OVERRIDE="$state" "$DRAIN" --all-open-decisions > "$out" || fail "full listing failed"
  grep -F 'task40' "$out" >/dev/null || fail "full listing omitted later decisions beyond the ordinary byte cap"
  if grep -F 'more omitted (byte cap)' "$out" >/dev/null; then
    fail "full listing reported omitted decisions despite its full-list contract"
  fi

  env -u FM_DRAIN_FULL_OPEN_DECISIONS LC_ALL="${FM_TEST_MULTIBYTE_LOCALE:-${LC_ALL:-C.UTF-8}}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "ordinary drain failed"
  grep -F 'more omitted (byte cap)' "$out" >/dev/null || fail "ordinary drain no longer applies its byte cap"
  bytes=$(LC_ALL=C wc -c < "$out" | tr -d ' ')
  [ "$bytes" -le 4200 ] || fail "ordinary drain exceeded its 4,000-byte section cap plus framing ($bytes bytes)"
  pass "full listing includes decisions beyond the ordinary drain byte cap"
}

test_tabbed_receipts_preserve_age_and_cooldown() {
  local dir state out now format
  for format in legacy timestamped; do
    dir=$(make_case "tabbed-$format")
    state="$dir/state"
    out="$dir/drain.out"
    now=$(date +%s)
    printf 'needs-decision [key=choice] [at=%s]: choose A\tor B\n' "$((now - 18000))" > "$state/task1.status"
    printf 'blocked [key=other] [at=%s]: choose C\tor D\n' "$((now - 18000))" >> "$state/task1.status"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "tabbed initial drain failed"
    grep -F "$(printf 'choose A\tor B')" "$out" >/dev/null || fail "tabbed note was changed"
    if [ "$format" = legacy ]; then
      printf 'task1\tchoice\tneeds-decision\tchoose A\tor B\ntask1\tother\tblocked\tchoose C\tor D\n' > "$state/.open-decisions-presented"
    fi
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "tabbed aged drain failed"
    grep -F 'needs-decision (open 5h' "$out" >/dev/null || fail "tabbed receipt lost decision age"
    grep -F 'blocked (open 5h' "$out" >/dev/null || fail "sibling key lost decision age"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "tabbed cooldown drain failed"
    grep -F 'OPEN DECISIONS: 2 unchanged' "$out" >/dev/null || fail "tabbed receipts bypassed cooldown"
    if grep -F 'choose ' "$out" >/dev/null; then fail "tabbed notes reprinted during cooldown"; fi
  done
  pass "legacy and timestamped tabbed receipts retain notes, age, and cooldown"
}

test_digest_view_shows_count_and_newest_five() {
  local dir state out i now
  dir=$(make_case digest-view)
  state="$dir/state"
  out="$dir/drain.out"
  now=$(date +%s)
  for i in 1 2 3 4 5 6 7 8; do
    printf 'needs-decision [key=k%s] [at=%s]: question number %s\n' "$i" "$((now - 1000 + i))" "$i" > "$state/task$i.status"
  done

  FM_DRAIN_FULL_OPEN_DECISIONS=1 FM_DRAIN_OPEN_DECISIONS_DIGEST=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "digest drain failed"
  grep -F 'OPEN DECISIONS: 8 open, newest 5 shown' "$out" >/dev/null || fail "digest is missing the count line: $(cat "$out")"
  [ "$(grep -c 'question number' "$out")" -eq 5 ] || fail "digest did not print exactly five entries: $(cat "$out")"
  for i in 8 7 6 5 4; do
    grep -F "question number $i" "$out" >/dev/null || fail "digest dropped a newest entry ($i): $(cat "$out")"
  done
  if grep -F 'question number 1' "$out" >/dev/null; then fail "digest kept an old entry over a newer one"; fi
  grep -F 'OPEN DECISIONS: 3 more not shown; list all: bin/fm-wake-drain.sh --all-open-decisions' "$out" >/dev/null \
    || fail "digest is missing the list-all line: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --all-open-decisions > "$out" || fail "full listing failed"
  [ "$(grep -c 'question number' "$out")" -eq 8 ] || fail "--all-open-decisions no longer lists every decision: $(cat "$out")"
  FM_DRAIN_OPEN_DECISIONS_DIGEST=1 FM_STATE_OVERRIDE="$state" "$DRAIN" --all-open-decisions > "$out" || fail "full listing with digest env failed"
  [ "$(grep -c 'question number' "$out")" -eq 8 ] || fail "digest env shrank --all-open-decisions"

  cp "$state/.open-decisions-presented" "$dir/presented.before"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --digest-open-decisions > "$out" || fail "read-only digest listing failed"
  [ "$(grep -c 'question number' "$out")" -eq 5 ] || fail "--digest-open-decisions did not keep five entries"
  cmp -s "$dir/presented.before" "$state/.open-decisions-presented" \
    || fail "the read-only digest listing changed the presented record"
  pass "the digest view prints a count and the newest five; the full listing stays whole"
}

test_digest_hidden_decisions_print_in_full_on_the_next_drain() {
  local dir state out i now
  dir=$(make_case digest-hidden-next)
  state="$dir/state"
  out="$dir/drain.out"
  now=$(date +%s)
  for i in 1 2 3 4 5 6 7; do
    printf 'needs-decision [key=k%s] [at=%s]: question number %s\n' "$i" "$((now - 1000 + i))" "$i" > "$state/task$i.status"
  done
  printf 'needs-decision [key=k8]: question number 8\n' > "$state/task8.status"

  FM_DRAIN_FULL_OPEN_DECISIONS=1 FM_DRAIN_OPEN_DECISIONS_DIGEST=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "digest drain failed"
  [ "$(grep -c 'question number' "$out")" -eq 5 ] || fail "digest did not print exactly five entries: $(cat "$out")"
  for i in 1 2 8; do
    if grep -F "question number $i" "$out" >/dev/null; then fail "digest printed a hidden entry ($i): $(cat "$out")"; fi
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "next drain failed"
  for i in 1 2 8; do
    grep -F "question number $i" "$out" >/dev/null || fail "next drain did not print hidden entry $i in full: $(cat "$out")"
  done
  for i in 3 4 5 6 7; do
    if grep -F "question number $i" "$out" >/dev/null; then fail "next drain re-printed digest entry $i: $(cat "$out")"; fi
  done
  grep -F 'OPEN DECISIONS: 5 unchanged' "$out" >/dev/null || fail "next drain miscounted the shown entries: $(cat "$out")"
  pass "decisions the digest hides print in full on the next drain, undated ones included"
}

test_digest_view_with_few_decisions_has_no_more_line() {
  local dir state out
  dir=$(make_case digest-few)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=only]: just one\n' > "$state/task1.status"
  FM_DRAIN_FULL_OPEN_DECISIONS=1 FM_DRAIN_OPEN_DECISIONS_DIGEST=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "digest drain failed"
  grep -F 'OPEN DECISIONS: 1 open, newest 1 shown' "$out" >/dev/null || fail "count line wrong: $(cat "$out")"
  if grep -F 'more not shown' "$out" >/dev/null; then fail "printed a more-line with nothing hidden"; fi
  pass "a digest with five or fewer decisions prints no hidden-count line"
}

test_buried_decision_still_surfaces
test_unchanged_decision_is_summarized_after_first_presentation
test_aged_open_decision_returns_on_every_drain
test_aged_decisions_rotate_and_new_decisions_go_first
test_aged_open_decision_age_limit_is_configurable
test_full_listing_is_read_only_and_bounded
test_full_listing_exceeds_ordinary_byte_cap
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed

test_tabbed_receipts_preserve_age_and_cooldown
test_digest_view_shows_count_and_newest_five
test_digest_hidden_decisions_print_in_full_on_the_next_drain
test_digest_view_with_few_decisions_has_no_more_line
