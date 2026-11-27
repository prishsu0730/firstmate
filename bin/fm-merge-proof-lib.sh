# shellcheck shell=bash
# Merge proof: what bin/fm-pr-merge.sh reads at merge time, read earlier.
# Usage: . bin/fm-merge-proof-lib.sh
#
# This file is the single owner of how the merge gate's proof inputs are read:
# the brief's `Type:` and `Review tier:` lines under `## Risk and review`
# (bin/fm-brief-labels-lib.sh owns which values they may carry), and
# the marker lines of <data>/<task-id>/red-green.log. bin/fm-pr-merge.sh sources
# it for the merge-time refusals, and bin/fm-dod-lib.sh sources it for the done
# gate, so the two cannot disagree about what counts. The line formats and the
# review count per tier stay documented in the bin/fm-pr-merge.sh header.
#
# A ship brief that carries the "# Merge proof" section (fm_merge_proof_block)
# opts in to the done gate: its `done:` naming a pull request is refused until
# a bug fix's red-green.log holds a red run at an ancestor of the head and a
# later green run of the same test, and until the ready report states the
# brief's review tier. The done gate does not bind the green run to a head,
# because the head the pipeline pushes may not be known here yet;
# bin/fm-pr-merge.sh still needs the green run at the live pull request head.
# The tier statement lets firstmate order the review the tier needs as soon as
# the pull request is ready, instead of meeting that refusal at merge time. The
# review line itself is never written here or by the worker: bin/fm-pr-merge.sh
# accepts one only from a reviewer other than the shipping task.
# A brief without the heading (older tasks, promoted scouts) is never gated.

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-brief-labels-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-brief-labels-lib.sh"

FM_MERGE_PROOF_HEADING='# Merge proof'

# 0 when <brief> opts in by carrying the Merge proof section.
fm_merge_proof_enforced() {  # <brief>
  [ -f "$1" ] || return 1
  grep -qxF -- "$FM_MERGE_PROOF_HEADING" "$1"
}

# Print every `<key>:` line of the brief's `## Risk and review` section, so a
# copy in prose elsewhere cannot stand in for it.
fm_merge_proof_risk_lines() {  # <brief> <key>
  local section
  section=$(fm_brief_task_heading_body "$1" "## Risk and review") || section=
  printf '%s\n' "$section" | grep "^$2:" || true
}

# Print `<red-sha> <test-id>` for every red run that has a later green run of the
# same test id and test command at <head>, in a log marker format that
# bin/fm-pr-merge.sh documents. With <any-green> set to 1, a green run at any
# commit counts. A marker counts only when captured output follows it before the
# next marker; the caller still checks that the red commit is an ancestor of the
# head. Returns nonzero when the log cannot be read.
fm_merge_proof_red_green_candidates() {  # <log> <pr-url> <head> [<any-green>]
  awk -F'|' -v url="$2" -v head="$3" -v any_green="${4:-0}" '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      function settle() {
        if (pending != "" && output && !invalid) {
          if (pending_kind == "red") red[pending SUBSEP pending_command SUBSEP pending_sha] = 1
          else for (key in red) { split(key, parts, SUBSEP); if (parts[1] == pending && parts[2] == pending_command) print parts[3] " " pending }
        }
        pending = ""; output = 0; invalid = 0
      }
      NF >= 6 && (trim($4) == "red" || trim($4) == "green") {
        settle()
        if (trim($1) != url) next
        sha = tolower(trim($2)); t = trim($3); kind = trim($4); code = trim($5)
        pending_command = $0
        for (i = 0; i < 5; i++) sub(/^[^|]*\|/, "", pending_command)
        pending_command = trim(pending_command)
        if (t == "" || t ~ /[[:space:]]/ || pending_command == "" || code !~ /^[0-9]+$/ || code + 0 == 126 || code + 0 == 127) next
        if (kind == "red" && sha ~ /^[0-9a-f]+$/ && length(sha) == 40 && sha != head && code + 0 != 0) { pending = t; pending_kind = "red"; pending_sha = sha }
        if (kind == "green" && (sha == head || (any_green == "1" && sha ~ /^[0-9a-f]+$/ && length(sha) == 40)) && code + 0 == 0) { pending = t; pending_kind = "green" }
        next
      }
      /[^[:space:]]/ { if (pending != "") { output = 1; if (tolower($0) ~ /command not found|no tests found/) invalid = 1 } }
      END {
        settle()
      }
    ' "$1"
}

# The problems that would stop this pull request at merge time, found now from
# local facts only: one line per problem on stdout, nothing when the proof is
# complete. <note> is the done note, <head> the commit the red run must be an
# ancestor of. Each problem line names the fix.
fm_merge_proof_problems() {  # <brief> <log> <worktree> <pr-url> <head> <note>
  local brief=$1 log=$2 wt=$3 url=$4 head=$5 note=$6
  local lines count class tier_lines tier_value tier_needed stated candidates sha test_id found
  lines=$(fm_merge_proof_risk_lines "$brief" Type)
  count=$(printf '%s' "$lines" | grep -c . || true)
  class=other
  if [ "$count" -gt 1 ]; then
    printf '%s\n' "the brief has more than one Type line under '## Risk and review', so whether this is a bug fix is ambiguous; firstmate must keep exactly one"
  elif [ "$count" -eq 1 ]; then
    class=$(fm_brief_type_class "${lines#Type:}") || class=unknown
    [ "$class" != unknown ] \
      || printf '%s\n' "the brief's Type line is not recognised, so whether this is a bug fix is unknown; firstmate must set it to $FM_BRIEF_TYPE_ACCEPTED"
  fi
  if [ "$class" = bug-fix ]; then
    found=
    if [ ! -f "$log" ] || [ ! -r "$log" ]; then
      printf '%s\n' "this bug fix has no readable $log; run the new test on the merge base and on the final head and append each run to it"
    else
      candidates=$(fm_merge_proof_red_green_candidates "$log" "$url" "$head" 1) || candidates=
      while read -r sha test_id; do
        [ -n "$sha" ] || continue
        if git -C "$wt" merge-base --is-ancestor "$sha" "$head" 2>/dev/null; then
          found=$test_id
          break
        fi
      done <<EOF
$candidates
EOF
      [ -n "$found" ] \
        || printf '%s\n' "$log holds no test that failed at an ancestor of head $head and then passed in a later run of the same test command; append <pr-url>|<sha>|<test-id>|red|<nonzero exit>|<test-command> and <pr-url>|<pr-head-sha>|<test-id>|green|0|<test-command>, each followed by its captured output; the merge needs the green run at the final pull request head"
    fi
  fi
  tier_lines=$(fm_merge_proof_risk_lines "$brief" 'Review tier')
  count=$(printf '%s' "$tier_lines" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    printf '%s\n' "the brief must hold exactly one Review tier line under '## Risk and review'; firstmate must fix it"
    return 0
  fi
  tier_value=$(fm_brief_review_tier_normalize "${tier_lines#Review tier:}")
  if ! tier_needed=$(fm_brief_review_tier_needed "${tier_lines#Review tier:}"); then
    printf '%s\n' "the brief's Review tier line is not recognised; firstmate must set it to one of $FM_BRIEF_REVIEW_TIER_ACCEPTED"
    return 0
  fi
  stated=$(printf '%s' "$note" | tr '[:upper:]' '[:lower:]')
  case $stated in
    *"review tier:"*) stated=$(fm_brief_review_tier_needed "${stated##*review tier:}") || stated= ;;
    *) stated= ;;
  esac
  [ "$stated" = "$tier_needed" ] \
    || printf '%s\n' "the ready report does not state the brief's review tier; add 'review tier: $tier_value' after the PR URL, copied from the brief's Review tier line, so firstmate orders the review at once"
}

# The brief section that tells the worker what the done gate needs. <root> is
# the firstmate code root, <data> the data directory.
fm_merge_proof_block() {  # <root> <data> <task-id>
  local root=$1 data=$2 id=$3
  cat <<EOF
$FM_MERGE_PROOF_HEADING
Your \`done:\` that names a PR is refused until the merge proof exists, because firstmate stops at merge time without it.
1. A bug fix (the \`Type:\` line under \`## Risk and review\`) needs \`$data/$id/red-green.log\` to hold both runs before you report done.
   Save the red run while you build: write the test first and run it on the merge base before your fix; a test file that does not exist there exits 127 and does not count, so run the new test file against the old code.
   Save the green run of the same command at the final PR head after the pipeline reports CI green; done needs the green run, and the merge needs it at the final PR head. The \`$root/bin/fm-pr-merge.sh\` header owns the line format.
2. Your ready report states the brief's review tier: \`done [at=<epoch>]: PR {url} checks green review tier: <the brief's Review tier value, such as MEDIUM (Base)>\`; any name of that same tier counts.
   A direct-PR report drops \`checks green\`.
3. Never write a review line. A reviewer other than you appends it; firstmate orders that review when it reads your tier.
EOF
}
