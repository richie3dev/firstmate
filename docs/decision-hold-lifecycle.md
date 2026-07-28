# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

A decision outlives the live backlog it was filed in.
`done_keep` retention moves a closed hold into the configured archive, and `tasks-axi show` cannot reach it there, so a lookup confined to the live backlog reports every long-resolved decision as absent and refuses the originating investigation's cleanup permanently.
The script therefore reads the live record first and falls back to the archived one through `fm_tasks_axi_archive_show` in `bin/fm-tasks-axi-lib.sh`, which resolves the archive path from the home's own `.tasks.toml` and renders the entry in the same field shape `tasks-axi show --full` prints.
That path resolution mirrors tasks-axi exactly: double-quoted and literal TOML strings both count, and a home with no `.tasks.toml` gets the tool's own default of `done-archive.md` beside the backlog, because tasks-axi does not walk up to a parent config and such a home still archives.
The archive is a wider view and never a lower bar: an archived entry passes only by carrying the same resolution record the live check demands, so a decision that was never registered, one that is still open, and one closed outside `resolve` all still refuse.

A hold identity is composed as `<origin-id>-decision-<decision-key>`, which two investigations can compose to the same string, so identity alone never proves a record answers for the origin asking.
A resolution therefore records the origin it answered for, and a record that names a different one refuses rather than lending its answer to another investigation.
Provenance is matched whenever a record carries it and is never required: every resolution written before origins were recorded names none, and refusing those would make each already-resolved decision start refusing again.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the origin, decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

Retention archives a closed hold, and tasks-axi cannot write into the archive, so `resolve` restores an archived captain hold into the live backlog before recording an answer against it.
Without that, an answer to a decision that had aged out could never be recorded at all: re-running `hold` cannot recover it either, because that path requires origin state teardown has already removed.
Restoring widens nothing else - the restored hold carries the unanswered body a fresh hold gets, so another investigation's archived answer is never inherited, and every routed task must still exist and still be durably blocked by the hold.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
Its secondmate-home summary classifies an active captain hold as `captain_decision` and preserves the owning home.

`bin/fm-bearings-snapshot.sh` projects active captain holds into `decisions_open` and excludes them from ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```

## Archived-resolution regression evidence

Verification date: 2026-07-28, tasks-axi 0.2.2.

The refusal was first observed on a real completed investigation whose five captain decisions had all been closed and then aged out of the live backlog by `done_keep = 10`.
The gate reported the first of them as absent, so cleanup could never run again.

Four of those five were resolved through `resolve` and pass once the lookup reaches the archive.
The fifth was closed with a plain `tasks-axi done` and its archived body still reads `State: awaiting captain decision.`, so the captain never answered it and the gate correctly keeps refusing.
That distinction is the point of the change and is pinned by its own regression: a closed captain hold is not an answered one, and reaching into the archive must not make it look like one.

With the three added regressions reverted to the pre-fix lookup, the first one reproduces the reported failure exactly.

```text
$ git stash push -- bin/fm-decision-hold.sh bin/fm-tasks-axi-lib.sh
$ bash tests/fm-decision-hold-lifecycle.test.sh
...
not ok - archived resolution failed the completion gate: fm-decision-hold: captain decision
sample-retention-review-decision-route is absent from
/tmp/fm-decision-hold.magWD9/archived-resolution/data/backlog.md

$ git stash pop
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a resolved decision keeps passing the completion gate after retention archives it
ok - the durable-decision lookup reads the archive the home actually configured
ok - unregistered and still-open archived decisions both still refuse
ok - an archived decision closed without an answer still refuses cleanup

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0) at /home/dev/.cache/firstmate/shellcheck/0.11.0/shellcheck
```

### Provenance, archived answers, and archive-path evidence

Verification date: 2026-07-28, tasks-axi 0.2.2.

Three further regressions cover what widening the lookup exposed.
Each was run against the pre-fix `bin/fm-decision-hold.sh` and `bin/fm-tasks-axi-lib.sh` and fails there for its own reason.

```text
$ git checkout -- bin/fm-decision-hold.sh bin/fm-tasks-axi-lib.sh
not ok - the gate ignored a literal-string archive path: fm-decision-hold: captain decision
sample-literal-archive-review-decision-route is absent from the
/tmp/fm-decision-hold.WfUQg0/literal-archive-path backlog and its archive
not ok - the archived resolution did not record the origin it answered for
not ok - an answer could not be recorded against an archived hold: fm-decision-hold: captain hold
sample-archived-answer-review-decision-gauge is absent from
/tmp/fm-decision-hold.MEsTja/archived-resolve/data/backlog.md
```

The compatibility regression is the inverse: it asserts that a resolution carrying no origin line still passes.
Making provenance required rather than matched-if-present fails it, which is how the pre-origin records are held safe.

```text
not ok - a resolution recorded before origins were written refused: fm-decision-hold: captain decision
sample-legacy-resolution-review-decision-route is neither actively held nor durably resolved
```

The tasks-axi 0.2.2 path rules the archive lookup now mirrors were read from its own `dist/src/config.js` rather than inferred: per-key resolution over `.tasks.toml` then `~/.tasks-axi/config.toml`, both quote styles, `dirname(path)/done-archive.md` when no archive is configured, and backlog discovery over `backlog.md` then `data/backlog.md`.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a resolved decision keeps passing the completion gate after retention archives it
ok - the durable-decision lookup reads the archive the home actually configured
ok - unregistered and still-open archived decisions both still refuse
ok - an archived decision closed without an answer still refuses cleanup
ok - the archive lookup reads literal-string and defaulted archive paths
ok - an archived resolution answers only the origin it names
ok - a resolution that names no origin keeps passing the completion gate
ok - an answer stays recordable after retention archives its captain hold

$ /home/dev/.cache/firstmate/shellcheck/0.11.0/shellcheck -x bin/fm-decision-hold.sh bin/fm-tasks-axi-lib.sh tests/fm-decision-hold-lifecycle.test.sh
(no output)
```
