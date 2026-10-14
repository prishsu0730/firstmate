#!/usr/bin/env bash
# Builds a disposable lab FM_HOME that mirrors the five "tonight" cases for /bearings.
# Usage: build-lab-fixture.sh <worktree> <lab-dir>   (lab-dir must not exist)
set -eu
WT=$1 LAB=$2
cd "$WT"
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
cat > "$LAB/data/backlog.md" <<'EOF'
## In flight
- [ ] w1-onboarding - Anita onboarding screen (repo: anita) (kind: ship) (since 2026-10-13)
- [ ] w2-checkin - Anita daily check-in flow (repo: anita) (kind: ship) (since 2026-10-13)
- [ ] w3-reminders - Anita reminder notifications (repo: anita) (kind: ship) (since 2026-10-13)
- [ ] w4-copy - Anita copy pass (repo: anita) (kind: ship) (since 2026-10-14)
- [ ] g1-stale - Old journal export (repo: anita) (kind: ship) (since 2026-10-01)
- [ ] g2-stale - Old settings page (repo: anita) (kind: ship) (since 2026-10-01)
- [ ] g3-stale - Old analytics probe (repo: anita) (kind: scout) (since 2026-10-02)
- [ ] g4-stale - Old icon refresh (repo: anita) (kind: ship) (since 2026-10-02)

## Queued
- [ ] q1-testflight - TestFlight build for testers blocked-by: ghost-a (repo: anita) (kind: ship) (filed 2026-10-10)
- [ ] q2-privacy - Privacy policy page blocked-by: ghost-b (repo: anita) (kind: ship) (filed 2026-10-10)
- [ ] q3-mood - Mood chart blocked-by: ghost-c (repo: anita) (kind: ship) (filed 2026-10-11)
- [ ] q4-widgets - Home widget blocked-by: ghost-d (repo: anita) (kind: ship) (filed 2026-10-11)
- [ ] q5-share - Share sheet blocked-by: ghost-e (repo: anita) (kind: ship) (filed 2026-10-12)
- [ ] q6-phone320 - Release concern: layout overflows on 320px phone width (repo: anita) (kind: ship) (filed 2026-10-13)
- [ ] h-live - Choose tester invite wording A or B (repo: anita) (kind: captain) (hold: parked) (hold-kind: captain) (filed 2026-10-14)
- [ ] h-dated - Decide paid plan pricing (repo: anita) (kind: captain) (hold: parked) (hold-kind: captain) (hold-until: 2026-11-01) (filed 2026-10-05)
- [ ] h-blocked - Approve App Store listing blocked-by: q1-testflight (repo: anita) (kind: captain) (hold: parked) (hold-kind: captain) (filed 2026-10-12)

## Done
- [x] d1 - Anita login screen https://github.com/example/anita/pull/12 (repo: anita) (kind: ship) (merged 2026-10-13)
EOF
for id in w1-onboarding w2-checkin w3-reminders w4-copy; do
  mkdir -p "$LAB/projects/$id"
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$LAB/projects/$id" project=anita harness=claude kind=ship mode=no-mistakes > "$LAB/state/$id.meta"
  gen=$(FM_HOME="$LAB" bin/fm-busy-event.sh arm "$LAB/state" "$id")
  FM_HOME="$LAB" bin/fm-busy-event.sh apply "$LAB/state" "$id" busy --gen "$gen" --source claude-hook --event user-prompt-submit
  printf 'working: building %s\n' "$id" > "$LAB/state/$id.status"
done
echo "$LAB"
