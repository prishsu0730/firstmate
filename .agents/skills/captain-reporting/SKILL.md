---
name: captain-reporting
description: Load before the first captain-facing message that reports fleet, worker, PR, or pipeline state, and whenever unsure how to phrase an internal term, escalation, or outcome for the captain.
user-invocable: false
metadata:
  internal: true
---

# captain-reporting

This skill is the single owner of the captain-facing vocabulary and escalation detail.
`AGENTS.md` section 9 keeps inline the outcomes-not-mechanics rule, the stand-alone final message, the verbatim-relay ban, the immediate-escalation list, the PR URL rule, and the `Captain, shipshape.` rule.

## Rewrite internal terms

Do not expose internal terms; rewrite them before sending.
Scout and second mate are accepted house vocabulary.

- worktree, checkout, or local-main -> local copy or local branch, only if the location matters.
- teardown -> cleanup.
- wake, watcher, heartbeat, stale, signal, check, polling, or lock -> notification, monitoring, waiting too long, or stopped responding.
- hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision, wait, approval, blocker, or external delay.
- done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result, review finding, passing or failed check, or stopped validation.
- brief -> instructions.
- crewmate -> worker, only when naming the helper matters.
- harness, backend, runtime, or adapter -> worker runtime or tool, only when the tool choice blocks work.
- status or metadata file, state, task id, or raw path -> durable record, or omit it unless the captain needs the path.
- startup machinery, promotion, context budgets, delivery-mode names, autonomy flags, wake types, status prefixes, decision holds, and pipeline step names -> the plain outcome.
- Safety labels get plain rewrites too: fail-closed, fails closed, fail loudly, or refuses loudly -> stops safely or refuses rather than proceeding; fail-open or degraded-open -> steps aside and lets work continue when the check cannot complete.

Use the captain's nouns: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the credential, the local copy, the worker, or the project.
Translate internal state into the project outcome, consequence, and next decision.

## Stand-alone replies

The final response message's recap may list all outstanding decisions and their URLs, but never replaces or combines any separate per-decision ask messages a harness's no-batching rule requires.
Private evidence reports may retain exact identifiers, paths, status lines, and internal terms, but the captain-facing chat summary still follows the translation rule.

## Escalations

Every escalation must stand alone and stay concise: lead with concrete evidence, then the consequence, options when applicable, and a recommendation; objections and clarifying challenges use the same evidence-first form.
Do not surface automatic fixes, retries, routine progress, or internal supervision mechanics.
Batch non-urgent updates into the next natural reply.
Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit from a visual surface.
For a captain-requested completion, or any wake needing the captain's review, approval, merge, or design pick, state what finished; a transcript entry or durable record already showing the substance does not discharge the reply.
Ask for the captain's word only when the next step requires a review, approval, merge, or design pick.
Mention cost as a courtesy when unusually much work is running, but never block on it.

## Secondmate homes

In a secondmate home, reaching the captain means appending the outcome to the parent channel your charter names; a captain-facing sentence in that home's chat has not been sent ([`docs/secondmate-parent-channel.md`](../../../docs/secondmate-parent-channel.md) owns which outcomes its scripts deliver there without you).
