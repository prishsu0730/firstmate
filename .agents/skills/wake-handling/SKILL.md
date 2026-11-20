---
name: wake-handling
description: Load on every actionable wake-handling turn - a `signal:`, `stale:`, `check:`, or `heartbeat:` wake, or a wake drain that prints `OPEN DECISIONS`, `UNREAD STATUS`, or `RECORD DIVERGENCE` - before acting on it.
user-invocable: false
metadata:
  internal: true
---

# wake-handling

This skill is the single owner of how firstmate handles each kind of actionable wake.
`AGENTS.md` section 8 keeps inline the one-live-cycle rule, drain-first, the acknowledgement rule, and the never-kill-watchers rule.
The emitted supervision block (`bin/fm-supervision-instructions.sh`, rendered from `docs/supervision-protocols/`) owns the wait shape and the arm mechanics for the primary harness, and `docs/architecture.md` and `docs/turnend-guard.md` own the mechanisms.

## Drain and acknowledge

At the start of every wake-handling turn, drain the durable wake queue before peeking, steering, or starting work; session start is the only exception because its digest already presented the queue.
Treat any `OPEN DECISIONS` or `UNREAD STATUS` drain section as actionable even when no wake record was queued; read unread status this turn because it is not re-printed.
Treat any `RECORD DIVERGENCE` section as a contradiction between two records of one captain call, never as proof the captain ruled; load `captain-hold-lifecycle` and reconcile it in whichever direction the evidence supports.
After handling, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; once an acknowledgement succeeds or reports a sequence already processed, never acknowledge that sequence again or retry the refusal.
A status line is a wake event, not current state; use `bin/fm-crew-state.sh` when current state matters, especially before re-escalating an old decision, blocker, or pause.
`bin/fm-classify-lib.sh` owns the distinction between declared `paused:` waits and `blocked:` events needing firstmate action; `bin/fm-brief.sh` owns worker declaration instructions.

## Handle each wake type

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result (merges, contribution signals, Relay events, process-to-event results, captain inbox notes); acknowledge a handled inbox note with `bin/fm-inbox.sh drain --ack <id>` and publish an answer the submitter must read with `bin/fm-inbox.sh reply <id>`.
   A `check: secondmate <id> auto-relaunched` wake records a completed recovery - reconcile current state rather than relaunching, and investigate a repeat or paused-bound wake.
   A `procevent` or `process-event source` wake routes to `process-event-sources`, not to a generic acknowledgement.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and never report an unchanged fleet as progress.

Load `bearings` on a contributions check wake or when filing work linked to an upstream issue; its contribution-follow-up section owns triage and exact signal acknowledgement.
When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; it owns the promised-final reconciliation and final completion follow-up required before terminal teardown.

## Standing supervision facts

A secondmate's idle endpoint is healthy; parent supervision relies on its routed status, not a quiet pane.
Waiting on a healthy supervision cycle is silent; no-change updates are not captain-facing progress.
Guard warnings do not replace the contract: resolve a worktree-tangle warning without touching unlanded work, and treat turn-end guards as backstops, not permission to omit the live cycle.
Do not substitute another harness's wait shape, use shell `&`, or create a second cycle when a healthy one exists.
