#!/usr/bin/env bash
# tests/fm-spawn-secondmate-env-isolation.test.sh - a secondmate launched from a
# polluted pane environment still runs in its OWN home.
#
# Incident (2026-10-17 and 2026-10-21): after a restart the tmux server, started
# from inside another home's startup run, held that run's FM_HOME,
# FM_STATE_OVERRIDE and process-state variables in its global environment, so
# every pane it created inherited them. A relaunched secondmate then ran
# another home's startup and left that home's wakes unhandled.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane, then EXECUTE the launch command the pane received under a
# synthetic polluted pane environment, with the harness replaced by a probe that
# prints what it was started with. The probe output is what a real agent saw.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-sm-env-isolation)

WRONG_HOME="$TMP_ROOT/wrong-home"

# Names a pane can carry in from the wrong home. Each is either a home selector
# or a per-run process-state variable that makes a startup behave like the run
# that started the tmux server.
LEAKED_NAMES="FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_PENDING_REPLY_DIR_OVERRIDE FM_SECONDMATE_PARENT_HOME FM_PROCEVENT_CLAIM_HOME FM_PROCEVENT_CLAIM_ROOT FM_PROCEVENT_CLAIM_STATE_ROOT FM_BOOTSTRAP_NETWORK FM_BOOTSTRAP_NETWORK_LOCK_PID FM_BOOTSTRAP_PARALLEL_DIR FM_SESSION_START_STAGE_FILE FM_SPAWN_NO_GUARD FM_TIMING_EPOCH_MS FM_TIMING_LOG FM_TASK_ID"

# polluted_env_args: the `NAME=value` words a polluted pane carries, one per line.
polluted_env_args() {
  local name
  printf 'FM_HOME=%s\n' "$WRONG_HOME"
  for name in $LEAKED_NAMES; do
    printf '%s=%s\n' "$name" "$WRONG_HOME/$name"
  done
}

# make_secondmate <name> <harness>
# Builds the launching home, a marked secondmate home, and a fake pane. Sets
# CASE_DIR HOME_DIR SM_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG.
make_secondmate() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  SM_DIR="$CASE_DIR/secondmate-home"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_test_spawn_brief "$HOME_DIR" "sm-$1"
  mkdir -p "$SM_DIR/bin" "$SM_DIR/data"
  printf '# Firstmate\n' > "$SM_DIR/AGENTS.md"
  printf '%s\n' "sm-$1" > "$SM_DIR/.fm-secondmate-home"
  printf 'charter for sm-%s\n' "$1" > "$SM_DIR/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM_DIR/.gitignore"
  git -C "$SM_DIR" init -q -b main
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
}

spawn_secondmate() {  # <id>
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$SM_DIR" "$FAKEBIN_DIR" "$1" "$SM_DIR" --secondmate
}

# Replace the harness binary with a probe printing `NAME=value` for the home
# selectors and every leaked name, or `NAME=<unset>`.
install_env_probe() {  # <fakebin> <harness>
  local name
  {
    printf '#!/bin/sh\n'
    for name in HOME FM_HOME FM_PUBLIC_FOLLOWUP_PRIMARY_HOME $LEAKED_NAMES; do
      # shellcheck disable=SC2016
      printf 'printf "%%s=%%s\\n" %s "${%s-<unset>}"\n' "$name" "$name"
    done
  } > "$1/$2"
  chmod +x "$1/$2"
}

# Run the emitted launch in a synthetic pane shell that carries the polluted
# environment, as a pane created by a tmux server with that global environment.
emitted_launch_env() {  # <fakebin> <launch-log> <pane-log> [env-name=value...]
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  shift 3
  launch=$(cat "$launchlog")
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane "$@" \
    /bin/sh -c "$preamble
$launch"
}

# probe_value <probe-output> <name>
probe_value() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

assert_own_home() {  # <seen> <label>
  local seen=$1 label=$2 name value want_home want_parent leaks=
  want_home=$(cd "$SM_DIR" && pwd -P)
  want_parent=$(cd "$HOME_DIR" && pwd -P)
  # Non-vacuity: the probe must have run inside the synthetic polluted pane.
  [ "$(probe_value "$seen" HOME)" = "$TMP_ROOT/pane-home" ] \
    || fail "$label: the probe did not run inside the synthetic pane (HOME=$(probe_value "$seen" HOME))"
  [ "$(probe_value "$seen" FM_HOME)" = "$want_home" ] \
    || fail "$label: FM_HOME should be the secondmate's own home $want_home, got $(probe_value "$seen" FM_HOME)"
  [ "$(probe_value "$seen" FM_PUBLIC_FOLLOWUP_PRIMARY_HOME)" = "$want_parent" ] \
    || fail "$label: FM_PUBLIC_FOLLOWUP_PRIMARY_HOME should name the launching home $want_parent, got $(probe_value "$seen" FM_PUBLIC_FOLLOWUP_PRIMARY_HOME)"
  for name in $LEAKED_NAMES; do
    value=$(probe_value "$seen" "$name")
    # An override left empty reads as unset to every script that consults it.
    [ -z "$value" ] || [ "$value" = '<unset>' ] || leaks="$leaks $name=$value"
  done
  [ -z "$leaks" ] || fail "$label: the secondmate inherited the polluting pane's$leaks"
}

test_polluted_pane() {
  local harness setting out status seen
  for harness in codex claude; do
    for setting in absent enabled; do
      make_secondmate "polluted-$harness-$setting" "$harness"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      out=$(spawn_secondmate "sm-polluted-$harness-$setting")
      status=$?
      expect_code 0 "$status" "$harness secondmate spawn with allowlist=$setting should succeed: $out"
      install_env_probe "$FAKEBIN_DIR" "$harness"
      # shellcheck disable=SC2046
      seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" $(polluted_env_args)) \
        || fail "$harness, allowlist=$setting: the emitted launch failed to run"
      assert_own_home "$seen" "polluted pane, $harness, allowlist $setting"
    done
  done
  pass "a secondmate launched from a polluted pane starts in its own home for each harness and allowlist posture"
}

test_polluted_pane

printf 'all tests passed\n'
