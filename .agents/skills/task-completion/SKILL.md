---
name: task-completion
description: >-
  Agent-only procedure for carrying a dispatched task from its worker's first return through validation, landing, cleanup, and scout promotion.
  Load before triggering or judging a no-mistakes validation run, when a ship task reports its PR or is ready to land or be cleaned up, before writing a custom state check, when a scout reports its report is ready, and before promoting a scout to implementation.
user-invocable: false
metadata:
  internal: true
---

# Task completion

This skill is the single owner of what firstmate does after a dispatched worker starts returning results.
`AGENTS.md` section 7 owns intake, dispatch, the selected delivery path, and approval authority, and keeps the trigger stubs that point here.
Those authority rules are not restated here: the configured merge authority, the never-merge-a-red-PR rule, and the never-tear-down-unlanded-work directive all remain owned by `AGENTS.md` and bind everything below.

## Validate

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
`no-mistakes axi run` without `--yes` blocks synchronously for the whole pipeline, minutes to tens of minutes, until a gate or outcome, so a quiet worker in that state is working rather than wedged.

An ask-user finding returns as `needs-decision`; firstmate decides only when the configured authority permits, otherwise escalates to the captain.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the current-code-matched run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## PR ready and landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/fm-pr-check.sh <id> <PR url>` - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
Tell the captain the PR's full URL, always the complete `https://...` link rather than a bare `#number`, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine authority.

## Custom state checks

The armed PR merge poll is generated, and needs no hand-authoring.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, and finish before `FM_CHECK_TIMEOUT`.
Then bind its current bytes with `bin/fm-check-register.sh <id>`; the watcher refuses to execute an unregistered or content-changed check, so an unbound check simply never runs.

## Cleanup

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
Read the report, relay its findings rather than merely saying it finished, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `decision-hold-lifecycle`; teardown enforces that shared completion gate.

When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path.
Scratch commits and debug edits never ride along, and a reproduced bug becomes the regression test.
