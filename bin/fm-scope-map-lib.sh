# shellcheck shell=bash
# Scope map: a mechanical presence check that a ship's `done:` covers its brief.
# Usage: . bin/fm-scope-map-lib.sh
#
# This file is the single owner of the scope-map contract. A ship brief carries a
# "# Scope map" section (fm_scope_map_block); a brief with that heading owes a
# map, and bin/fm-dod-lib.sh refuses the worker's `done:` until the map is
# complete. A brief without the heading (older tasks, promoted scouts) is never
# gated, so the check changes nothing for work launched before it existed.
#
# Items: every top-level numbered or bulleted line (`1.`, `1)`, `-`, `*`, `+`,
# indented at most three spaces, outside code fences) under the brief's
# `## Captain's intent` and `## Firstmate spec`. Keys are positional: I1, I2, ...
# for the intent and S1, S2, ... for the spec. Prose and nested bullets are not
# items.
#
# Map: `<fm data>/<task-id>/scope-map.md`, one line per item, `KEY: ref ...`.
# A ref is a commit SHA (7 to 40 hex characters) the branch carries beyond its
# base, or a file path the branch changed against its base. `KEY: n/a <reason>`
# says the item needs no change and keeps the reason where firstmate reads it.
# This is a presence-and-resolution check, not a judge: it never reads whether a
# change actually satisfies an item.
#
# When the worktree is not a readable git copy, or its base cannot be resolved
# (a merged branch), refs are checked only as far as that allows; presence of a
# line for every item is always required.

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-brief-heading-lib.sh"

FM_SCOPE_MAP_HEADING='# Scope map'
FM_SCOPE_MAP_SECTIONS=("## Captain's intent:I" "## Firstmate spec:S")

# Where this task's map lives.
fm_scope_map_path() {  # <data-dir> <task-id>
  printf '%s/%s/scope-map.md\n' "$1" "$2"
}

# 0 when <brief> opts in by carrying the Scope map section.
fm_scope_map_enforced() {  # <brief>
  [ -f "$1" ] || return 1
  grep -qxF -- "$FM_SCOPE_MAP_HEADING" "$1"
}

# Print `KEY<TAB>text` for every item the brief names, in order.
fm_scope_map_items() {  # <brief>
  local brief=$1 spec heading prefix
  [ -f "$brief" ] || return 0
  for spec in "${FM_SCOPE_MAP_SECTIONS[@]}"; do
    heading=${spec%:*}
    prefix=${spec##*:}
    fm_brief_heading_body "$brief" "$heading" | awk -v prefix="$prefix" '
      {
        line = $0
        scan = line
        spaces = 0
        while (spaces < 3 && substr(scan, 1, 1) == " ") { scan = substr(scan, 2); spaces++ }
        if (scan ~ /^(```|~~~)/) { fenced = !fenced; next }
        if (fenced) next
        if (substr(line, 1, 4) == "    " || substr(line, 1, 1) == "\t") next
        if (scan ~ /^([-*+]|[0-9]+[.)])[ \t]+[^ \t]/) {
          sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", scan)
          if (length(scan) > 100) scan = substr(scan, 1, 97) "..."
          n++
          printf "%s%d\t%s\n", prefix, n, scan
        }
      }'
  done
}

# Print `KEY<TAB>refs` for every map line, last one per key winning.
fm_scope_map_entries() {  # <map>
  [ -f "$1" ] || return 0
  awk '
    {
      line = $0
      sub(/^[ \t]*([-*+][ \t]+)?/, "", line)
      gsub(/`/, "", line)
      if (match(line, /^[IS][0-9]+[ \t]*:/)) {
        key = substr(line, 1, RLENGTH)
        sub(/[ \t]*:$/, "", key)
        rest = substr(line, RLENGTH + 1)
        sub(/^[ \t]+/, "", rest)
        sub(/[ \t]+$/, "", rest)
        if (!(key in seen)) { order[++count] = key }
        seen[key] = 1
        value[key] = rest
      }
    }
    END { for (i = 1; i <= count; i++) printf "%s\t%s\n", order[i], value[order[i]] }
  ' "$1"
}

# The commit a branch started from: the merge-base with the first resolvable of
# origin/<base>, <base>, origin/HEAD, origin/main, origin/master, main, master.
# Empty when none resolves or the branch is already contained in it (merged).
fm_scope_map_base() {  # <worktree> [<base-branch>]
  local wt=$1 candidate base head
  head=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null) || return 0
  for candidate in ${2:+"origin/$2" "$2"} origin/HEAD origin/main origin/master main master; do
    base=$(git -C "$wt" merge-base HEAD "$candidate" 2>/dev/null) || continue
    [ -n "$base" ] || continue
    [ "$base" = "$head" ] && return 0
    printf '%s\n' "$base"
    return 0
  done
}

# 0 when <ref> is a commit the branch carries beyond <base> or a file it changed
# against <base>. An empty <base> accepts any commit reachable from HEAD and any
# file present in HEAD.
fm_scope_map_ref_resolves() {  # <worktree> <base> <ref>
  local wt=$1 base=$2 ref=$3 sha path
  ref=${ref%[.;]}
  if printf '%s' "$ref" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
    sha=$(git -C "$wt" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null) || return 1
    git -C "$wt" merge-base --is-ancestor "$sha" HEAD 2>/dev/null || return 1
    if [ -n "$base" ] && git -C "$wt" merge-base --is-ancestor "$sha" "$base" 2>/dev/null; then
      return 1
    fi
    return 0
  fi
  path=$ref
  case "$path" in
    *:[0-9]*) path=${path%%:[0-9]*} ;;
  esac
  [ -n "$path" ] || return 1
  if [ -z "$base" ]; then
    git -C "$wt" cat-file -e "HEAD:$path" 2>/dev/null
    return
  fi
  [ -n "$(git -C "$wt" diff --name-only --no-renames "$base" HEAD -- "$path" 2>/dev/null)" ]
}

# Print one line per problem and return 1 when the map leaves an item uncovered.
# A missing brief, a brief without items, or a brief that does not opt in is
# complete by definition.
fm_scope_map_problems() {  # <brief> <map> [<worktree> [<base-branch>]]
  local brief=$1 map=$2 wt=${3:-} base_branch=${4:-} base='' refs=0 bad=0
  local key text entries ref value token
  fm_scope_map_enforced "$brief" || return 0
  local items
  items=$(fm_scope_map_items "$brief")
  [ -n "$items" ] || return 0
  if [ -n "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    refs=1
    base=$(fm_scope_map_base "$wt" "$base_branch")
  fi
  entries=$(fm_scope_map_entries "$map")
  while IFS=$'\t' read -r key text; do
    [ -n "$key" ] || continue
    value=$(printf '%s\n' "$entries" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')
    if [ -z "$value" ]; then
      printf '%s\n' "$key has no mapping ($text)"
      bad=1
      continue
    fi
    if printf '%s' "$value" | grep -Eiq '^n/a([[:space:]]*[-:][[:space:]]*|[[:space:]]+)[^[:space:]]'; then
      continue
    fi
    if printf '%s' "$value" | grep -Eiq '^n/a$'; then
      printf '%s\n' "$key says n/a without a reason ($text)"
      bad=1
      continue
    fi
    [ "$refs" = 1 ] || continue
    for token in $(printf '%s' "$value" | tr ',' ' '); do
      ref=$token
      if ! fm_scope_map_ref_resolves "$wt" "$base" "$ref"; then
        printf '%s\n' "$key maps to $ref, which is not a commit or changed file on this branch ($text)"
        bad=1
      fi
    done
  done <<EOF
$items
EOF
  [ "$bad" = 0 ]
}

# The brief section that tells the worker what to write. <root> is the firstmate
# code root, <data> the data directory.
fm_scope_map_block() {  # <root> <data> <task-id>
  local root=$1 data=$2 id=$3
  cat <<EOF
$FM_SCOPE_MAP_HEADING
Your \`done:\` is refused until every numbered or bulleted item under \`## Captain's intent\` and \`## Firstmate spec\` maps to a change on your branch.
1. List the items and their keys: \`'$root/bin/fm-scope-map.sh' items '$data/$id/brief.md'\`
2. Write \`$data/$id/scope-map.md\`, one line per item, like \`I1: <commit sha>\` or \`S2: bin/some-file.sh\`.
   A ref is a commit your branch carries or a file your branch changed. Use \`S3: n/a <reason>\` only when an item truly needs no change; firstmate reads the reason.
3. Run \`'$root/bin/fm-scope-map.sh' check '$data/$id/brief.md' '$data/$id/scope-map.md'\` from your worktree and fix every line it prints before you report done.
This is a presence check only; it does not judge whether a change satisfies an item.
EOF
}
