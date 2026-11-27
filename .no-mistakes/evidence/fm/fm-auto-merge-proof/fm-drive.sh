#!/usr/bin/env bash
# Drives the real fm-brief.sh and fm-pr-check.sh against a disposable lab home.
set -u
ROOT={run-worktree}
LAB=/var/folders/cp/dj_1dxy11bn_km_1vbw0m_p00000gn/T//fm-lab.gDroww
R=$LAB/wt
BASE=a1873a2b5146032a440ef951911212d53f787c90
TESTC=b7c83eeac52d0440667df2a47f19dd4679aff85d
HEAD=46997980ad9e15cef8480395a2e88f6944281672
URL=https://github.com/example/demo/pull/7
SFX=${SFX:-}
git -C "$R" update-ref refs/remotes/origin/fm/bug-task "$HEAD"; echo "pushed-branch ref set: refs/remotes/origin/fm/bug-task -> ${HEAD:0:8}"
mkdir -p "$LAB/fakebin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/fakebin/gh"; chmod +x "$LAB/fakebin/gh"
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_GUARD_GRACE=999999 "$@"; }
# Record a real run of the test at <sha> into the task's red-green.log.
record() {  # <id> <sha> <red|green>
  local id=$1 sha=$2 kind=$3 out rc
  git -C "$R" checkout -q "$sha"
  out=$(bash "$R/labdemo/test.sh" 2>&1); rc=$?
  git -C "$R" checkout -q fm/bug-task
  printf '%s|%s|add-test|%s|%s|bash labdemo/test.sh\n%s\n' "$URL" "$sha" "$kind" "$rc" "$out" >> "$LAB/data/$id/red-green.log"
  echo "  recorded $kind run at ${sha:0:8}: exit $rc: $out"
}
mktask() {  # <id> <type> <tier> [keep-heading]
  local id=$1 b
  run "$ROOT/bin/fm-brief.sh" "$id" alpha --mode no-mistakes >/dev/null 2>&1 || { echo "fm-brief.sh failed for $id"; return 1; }
  b=$LAB/data/$id/brief.md
  sed "s/^Type: {TYPE}\$/Type: $2/; s/^Review tier: {REVIEW_TIER} .*\$/Review tier: $3/" "$b" > "$b.tmp" && mv "$b.tmp" "$b"
  if [ "${4:-yes}" = no ]; then sed '/^# Merge proof$/,/^3\. Never write a review line/d' "$b" > "$b.tmp" && mv "$b.tmp" "$b"; fi
  printf 'project=x\nworktree=%s\nmode=no-mistakes\n' "$R" > "$LAB/state/$id.meta"
}
check() {  # <id> <done line>
  printf '%s\n' "$2" >> "$LAB/state/$1.status"
  echo "  ready report: $2"
  out=$(run "$ROOT/bin/fm-pr-check.sh" "$1" "$URL" 2>&1); rc=$?
  echo "  fm-pr-check.sh exit $rc; check.sh written: $([ -e "$LAB/state/$1.check.sh" ] && echo yes || echo no)"
  printf '%s\n' "$out" | sed 's/^/    | /' | head -8
}
DONE="done [at=1]: PR $URL checks green"

echo "== S1 brief scaffold =="
run "$ROOT/bin/fm-brief.sh" s1$SFX alpha --mode no-mistakes >/dev/null 2>&1; echo "  no-mistakes brief exit $?"
sed -n '/^# Merge proof$/,/^3\. /p' "$LAB/data/s1$SFX/brief.md" | sed 's/^/    > /'
run "$ROOT/bin/fm-brief.sh" s1local$SFX alpha --mode local-only >/dev/null 2>&1; echo "  local-only brief exit $?"
echo "  local-only Merge proof headings: $(grep -cx '# Merge proof' "$LAB/data/s1local$SFX/brief.md")"

echo "== S2 bug fix, no proof saved =="
mktask s2$SFX 'bug fix' 'MEDIUM (Base)'
check s2$SFX "$DONE"

echo "== S3 bug fix, red only =="
mktask s3$SFX 'bug fix' 'MEDIUM (Base)'
record s3$SFX "$TESTC" red
check s3$SFX "$DONE review tier: MEDIUM (Base)"

echo "== S4 bug fix, real red + green + tier =="
mktask s4$SFX 'bug fix' 'MEDIUM (Base)'
record s4$SFX "$TESTC" red
record s4$SFX "$HEAD" green
check s4$SFX "$DONE review tier: MEDIUM (Base)"

echo "== S5 tier wording: synonym accepted, wrong tier refused =="
mktask s5a$SFX 'bug fix' 'MEDIUM (Base)'; record s5a$SFX "$TESTC" red >/dev/null; record s5a$SFX "$HEAD" green >/dev/null
check s5a$SFX "$DONE review tier: medium"
mktask s5b$SFX 'bug fix' 'MEDIUM (Base)'; record s5b$SFX "$TESTC" red >/dev/null; record s5b$SFX "$HEAD" green >/dev/null
check s5b$SFX "$DONE review tier: HIGH (Plus)"
mktask s5c$SFX 'bug fix' 'MEDIUM (Base)'; record s5c$SFX "$TESTC" red >/dev/null; record s5c$SFX "$HEAD" green >/dev/null
check s5c$SFX "$DONE"

echo "== S6 fake red: test passes at red sha (exit 0) =="
mktask s6$SFX 'bug fix' 'MEDIUM (Base)'
record s6$SFX "$HEAD" green >/dev/null
printf '%s|%s|add-test|red|127|bash labdemo/test.sh\nbash: labdemo/test.sh: No such file\n' "$URL" "$BASE" >> "$LAB/data/s6$SFX/red-green.log"
echo "  appended red at base with exit 127 (test file missing)"
check s6$SFX "$DONE review tier: base"

echo "== S7 feature: tier only, no log needed =="
mktask s7$SFX 'Feature' 'LOW'
check s7$SFX "$DONE review tier: low"

echo "== S8 legacy brief without Merge proof section =="
mktask s8$SFX 'bug fix' 'MEDIUM (Base)' no
echo "  Merge proof headings: $(grep -cx '# Merge proof' "$LAB/data/s8$SFX/brief.md")"
check s8$SFX "$DONE"
