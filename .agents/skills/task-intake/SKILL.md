---
name: task-intake
description: Load at every captain work request before routing, classifying, or dispatching it, before writing a crewmate brief, before steering a live worker or relaying a mid-task captain ask, and before filing, holding, or re-queuing backlog work.
user-invocable: false
metadata:
  internal: true
---

# task-intake

This skill is the single owner of how firstmate takes in, classifies, dispatches, steers, and queues work.
`AGENTS.md` section 7 keeps only the merge, isolation, and steering safety rules inline; everything else about the task lifecycle is here.
`ship-landing` owns the merge-authority contract, landing, and cleanup.

## Intake and authority

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list.
Keep `local-only` work in the main home.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it, and do not read its chat: routed replies return through its status or a referenced document.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need.

Before commissioning an investigation, consult existing reports and established evidence.
Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep remaining bounded research inside it unless unresolved uncertainty could change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could change whether or what to build.

- If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question rather than dispatching speculative design work.
- Never both present a likely-enough solution and launch a parallel design exercise not expected to change it.
- A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to change code.
- Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.

## Delivery mode, yolo, and branch resolution

Resolve every ship task's concrete delivery mode and `yolo` merge posture at intake.
Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion; each command refuses to guess the values it consumes.
A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
Resolve the project's registered ship-branch prefix the same way, via `bin/fm-project-mode.sh --branch-prefix <project>`, and pass it as `--branch-prefix` to the brief, ship spawn, and scout promotion (default `fm/` needs no flag).
When the work must start from and target a non-default branch, pass it to the ship or scout brief and spawn as `--base-branch <branch>`; any promotion reads it from task meta.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
An unregistered project or absent registry resolves to `no-mistakes` with yolo off, and the registration gap goes to the captain.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

## Parallel dispatch and capacity

Treat file or subsystem overlap as a risk signal, not a reason to wait: dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the delivery path can reconcile ordinary rebases or conflicts.
A project's declared machine capacity (`config/project-capacity`) still bounds dispatch: a spawn beyond it exits 75 without launching, and its item stays queued rather than blocked.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient.
Write the task-specific brief (below) before spawning; when its instructions reuse an existing commit or branch, name the task it replaces and close or hold that task in the same step, passing `--supersedes <task>` to spawn.

## Dispatch profile routing

`AGENTS.md` section 4 keeps the always-loaded intake boundary; the rest of the routing procedure is here.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Never call a profile-array result quota-informed without having loaded `quota-array-dispatch`, and never infer a credential store, provider family, or quota mapping from a harness, model, or source name.
Never launch another harness's CLI to judge a candidate.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass its `profile:` line to `fm-spawn` unless you state a reason to override; any other result means the intake above (`docs/configuration.md` "Typed dispatch resolution").
`harness-adapters` owns the generic effort fallback and its precedence; never add model-specific versions of that policy.
`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.

## Dispatch and supervision handoff

Spawn only through `bin/fm-spawn.sh` after the profile and backend checks in `AGENTS.md` section 4.
The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assertion stops the task.
When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses when this home has no item for the work (manual-backend contract: `docs/configuration.md`).
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with ordinary text through fail-closed `fm-send`, which leaves a durable message in the task's steering inbox and rings only a doorbell line in the worker's terminal; `bin/fm-send.sh` owns delivery, remote transport, and the `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend, the only safe retry after unconfirmed delivery.
Pass `--resolve-key` when a steer answers an open keyed decision or blocker; never use `fm-send` for interrupt, exit, or other lifecycle control, because the worker would reason about it as chat instead of executing it.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
`bin/fm-pending-reply-lib.sh` owns the correlation, recovery, and escalation contract for marked secondmate requests.
When the captain adds or changes an ask mid-task, append the captain's words, without speaker labels or direct address, to that brief's `## Captain's intent` and relay them to the worker; Firstmate build constraints stay in `## Firstmate spec` or the steer.
Supervise all live work under `AGENTS.md` section 8.

## Delivery path rigor

The selected delivery path owns its own rigor.
Keep local commits focused and granular as cheap checkpoints, batch obvious local corrections before a remote push, match CI, no-mistakes, and Greptile depth to the change level, and run each remote check against a stable coherent head.
When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.
Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.
A separate review or audit is allowed only when the captain explicitly requests that deliverable or the task is a knowledge-only review.
If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.
The path's worker, automated gates, and captain approval remain authoritative: **no-mistakes** runs the full pipeline through a PR, **direct-PR** has the worker push and open a PR without it, and **local-only** has the worker stop with a clean ready branch, each then waiting for the configured merge authority (local-only via the guarded fast-forward path).
`ship-landing` owns that merge authority.

## Crewmate briefs

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and stated boundaries plus the context needed to read it, including the substance of any report, decision, or PR it refers to; never widen the ask into a general goal or coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow; generalization or extra hardening the captain did not ask for is follow-up work to note, not scope.
`bin/fm-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, what a no-mistakes worker may pass as `--intent`, and the string's self-sufficiency rule.
Keep additions task-specific, and alter generated sections only when the task genuinely differs from the standard shape.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.

## Backlog contract

The configured `tasks-axi` backend is the durable queue; the tracked default is `data/backlog.md`.
It tracks work items only, never agents; persistent secondmates never appear as backlog items.
Work routed to a secondmate is recorded in that secondmate home's own backlog, not the main backlog.
A decision is simply a task held for the captain: create the task with `bin/fm-tasks-axi.sh add` when needed, then always hold it through `bin/fm-captain-hold.sh hold <id> --reason "<reason>"`, with `--until <date>` when the captain defers it.
When a main-side thread such as a pending captain decision is worth durable tracking, file it as its own work item and hold it through that wrapper.
Captain calls discovered by investigations or visual reviews follow `captain-hold-lifecycle`, which owns their completion gate and recorded-answer rules.
When the automatic transition gate applies, `bin/fm-spawn.sh` and `bin/fm-teardown.sh` move the item themselves and refuse without it, so yours is filing the item before dispatch, recording decisions, and keeping notes current (`docs/configuration.md` owns gate applicability and the manual-backend exception).
Re-evaluate queued work after every teardown and heartbeat, and after a recorded PR-ready handoff when `config/project-capacity` caps that project, dispatching only when dependencies, time gates, and capacity have cleared.

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
Use compatible `tasks-axi` when the configured backend selects it, always through `bin/fm-tasks-axi.sh`, and the documented manual path otherwise.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

Keep free-form notes free of temporary paths, moving versions, and copied state that will rot; verify volatile details against their authoritative source and correct stale prose immediately.
Inspect the current task note before replacing its body and archive the superseded body when recoverability matters.
Preserve durable identifiers, dependencies, and completion artifact links, and route reusable knowledge to `AGENTS.md` section 6.
