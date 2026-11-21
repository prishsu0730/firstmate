# shellcheck shell=bash
# Brief label values.
# Usage: . bin/fm-brief-labels-lib.sh   (after bin/fm-brief-heading-lib.sh)
#
# This file is the single owner of the values the `## Risk and review` labels
# `Review tier:` and `Type:` may carry. bin/fm-pr-merge.sh reads them at merge
# time to decide the review depth and whether a bug-fix proof is due, and
# bin/fm-spawn.sh refuses a brief whose value this file rejects, so a bad label
# is caught when the brief is written to the worker rather than at merge.
# bin/fm-brief.sh owns the scaffold lines and the depths the tier names.

# The accepted values as the refusals print them.
FM_BRIEF_REVIEW_TIER_ACCEPTED='LOW (No Greptile), MEDIUM (Base), HIGH (Plus), CRITICAL (Apex)'
FM_BRIEF_TYPE_ACCEPTED="'bug fix' or a non-bug-fix type such as feature, docs, chore, or refactor"

# Print the value of a `Review tier:` line as it is matched: lowercase, trimmed,
# without the scaffold's trailing ` (No Greptile / Base / Plus / Apex)`.
fm_brief_review_tier_normalize() {  # <text after "Review tier:">
  local value
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//')
  printf '%s' "${value%' (no greptile / base / plus / apex)'}"
}

# Print the number of reviews a tier needs, or return 1 for a value that is not
# one unambiguous tier.
fm_brief_review_tier_needed() {  # <text after "Review tier:">
  case "$(fm_brief_review_tier_normalize "$1")" in
    low|'no greptile') printf '0' ;;
    base|medium|'medium (base)') printf '1' ;;
    plus|high|'high (plus)') printf '2' ;;
    apex|critical|'critical (apex)') printf '4' ;;
    *) return 1 ;;
  esac
}

# Print `bug-fix` or `other` for a `Type:` value, or return 1 for one that is not
# recognised.
fm_brief_type_class() {  # <text after "Type:">
  local value
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//')
  case "$value" in
    'bug fix'|bug-fix|bugfix|fix) printf 'bug-fix' ;;
    feat|feature|docs|chore|refactor|test|ci|build|perf|style|revert) printf 'other' ;;
    *) return 1 ;;
  esac
}

# Refuse a brief whose `Review tier:` or `Type:` line under `## Risk and review`
# carries a value the merge gate would not accept, or repeats the line, which the
# merge gate also refuses. Prints each refusal on stderr and returns 1; a missing
# line is not judged here, because fm-pr-merge.sh owns what an absent line means.
fm_brief_labels_check() {  # <brief-file>
  local brief=$1 section line value status=0 count
  section=$(fm_brief_task_heading_body "$brief" "## Risk and review") || section=
  count=$(printf '%s\n' "$section" | grep -c '^Review tier:' || true)
  if [ "$count" -gt 1 ]; then
    printf "error: %s has more than one Review tier line under '## Risk and review', which bin/fm-pr-merge.sh refuses at merge; keep exactly one\n" "$brief" >&2
    status=1
  fi
  count=$(printf '%s\n' "$section" | grep -c '^Type:' || true)
  if [ "$count" -gt 1 ]; then
    printf "error: %s has more than one Type line under '## Risk and review', which bin/fm-pr-merge.sh refuses at merge; keep exactly one\n" "$brief" >&2
    status=1
  fi
  while IFS= read -r line; do
    value=${line#Review tier:}
    fm_brief_review_tier_needed "$value" >/dev/null && continue
    printf "error: %s has a Review tier that bin/fm-pr-merge.sh would refuse at merge (read '%s'); set the 'Review tier:' line under '## Risk and review' to one of %s\n" \
      "$brief" "$(fm_brief_review_tier_normalize "$value" | tr -d '[:cntrl:]')" "$FM_BRIEF_REVIEW_TIER_ACCEPTED" >&2
    status=1
  done < <(printf '%s\n' "$section" | grep '^Review tier:' || true)
  while IFS= read -r line; do
    value=${line#Type:}
    fm_brief_type_class "$value" >/dev/null && continue
    printf "error: %s has a Type that bin/fm-pr-merge.sh would refuse at merge (read '%s'); set the 'Type:' line under '## Risk and review' to %s\n" \
      "$brief" "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//' | tr -d '[:cntrl:]')" "$FM_BRIEF_TYPE_ACCEPTED" >&2
    status=1
  done < <(printf '%s\n' "$section" | grep '^Type:' || true)
  return "$status"
}
