#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d "$ROOT/.fm-lab-home-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
helper="$ROOT/bin/fm-lab-home.sh"
mkdir "$fixture/tmp"

bash "$helper" create "$fixture/home" >/dev/null
TMPDIR="$fixture/tmp" bash "$helper" teardown "$fixture/home"
[ ! -e "$fixture/home" ]

bash "$helper" create "$fixture/home" >/dev/null
printf '/tmp/fml.invalid\n' > "$fixture/home/state/.fm-lab-tmux-dir"
ln -s "$fixture/home" "$fixture/alias"
if bash "$helper" teardown "$fixture/alias" > "$fixture/output" 2>&1; then
  echo 'teardown accepted a symlinked home' >&2
  exit 1
fi
[ -f "$fixture/home/state/.fm-lab-tmux-dir" ]
[ -d "$fixture/home" ]
printf 'PASS: explicit lab roots are removed and unsafe homes preserved\n'
