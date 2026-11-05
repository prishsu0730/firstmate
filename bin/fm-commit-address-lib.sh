# shellcheck shell=bash
# Direct-address word list for commit messages.
# Usage: . bin/fm-commit-address-lib.sh; jq --arg re "$FM_COMMIT_ADDRESS_RE" 'test($re; "i")'
#
# ONE OWNER for what counts as a commit message that addresses the operator.
# bin/fm-pr-merge.sh refuses a merge on it, and bin/fm-commit-address-check.sh
# catches it before push while a plain local amend can still fix it. Both read
# this pattern so the early check can never pass what the merge guard refuses.
#
# The pattern is an Oniguruma regex for jq's case-insensitive test(). It matches
# the whole word "captain". Hyphenated, underscored, dotted, and slash-joined
# tokens such as captain-hold and data/captain.md are exempt only when the
# joining punctuation has a letter or digit on both sides.

# shellcheck disable=SC2034  # read by the scripts that source this file
FM_COMMIT_ADDRESS_RE='(^|[^[:alnum:]_./-]|(^|[^[:alnum:]])[_./-])captain(?![[:alnum:]]|[_./-][[:alnum:]])'
