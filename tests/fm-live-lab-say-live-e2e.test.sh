#!/usr/bin/env bash
# Real lab prompt-integrity guard. Submits a long multiline prompt to every
# installed lab-supported primary; unavailable tools are named. Claude by default.
# FM_LIVE_LAB_SAY=1 bin/fm-test-run.sh tests/fm-live-lab-say-live-e2e.test.sh
# FM_LIVE_LAB_SAY_HARNESSES overrides the default "claude" set (Pi is untested).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_LIVE_LAB_SAY tmux python3
TMP_ROOT=$(fm_test_tmproot fm-live-lab-say-live)
LAB=
cleanup() {
  [ -z "$LAB" ] || bash "$ROOT/bin/fm-live-lab.sh" down "$LAB"
}
trap 'cleanup; fm_test_cleanup' EXIT
checked=0
prompt=$(python3 - <<'PY'
print("FIRST: run no tools; reply only INTEGRITY_OK.\n" +
      "Harmless multiline integrity padding with spaces and 台灣.\n" * 100 +
      "LAST: run no tools; reply only INTEGRITY_OK.")
PY
)
for harness in ${FM_LIVE_LAB_SAY_HARNESSES:-claude}; do
  case "$harness" in claude|pi) ;; *) fail "unsupported lab harness: $harness" ;; esac
  if ! command -v "$harness" >/dev/null 2>&1; then
    echo "# absent lab harness: $harness"
    continue
  fi
  version=$("$harness" --version 2>&1)
  # The helper owns isolation, credentials, trust registration, and teardown.
  # Keep the log outside every repo, and retain the root even if up fails.
  log="$TMP_ROOT/$harness.log"
  bash "$ROOT/bin/fm-live-lab.sh" up --harness "$harness" --timeout 90 > "$log" 2>&1
  rc=$?
  LAB=$(sed -n 's/^lab: \([^ ]*\) .*/\1/p' "$log" | head -n 1)
  cat "$log"
  [ "$rc" -eq 0 ] || fail "$harness $version: lab startup failed"
  out=$(bash "$ROOT/bin/fm-live-lab.sh" say "$LAB" "$prompt" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "$harness $version: full prompt not verified: $out"
  assert_contains "$out" 'full prompt verified' "$harness transcript receipt"
  pass "$harness $version: complete long multiline prompt verified"
  cleanup
  LAB=
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "no installed lab harness checked"
