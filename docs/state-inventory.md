# Operational home file inventory

This document is the single owner of the exhaustive per-file inventory of a firstmate operational home.
[`docs/configuration.md`](configuration.md) ("Operational home layout and state") owns the top-level layout and the configuration schemas, and each producing script's header and `--help` own exact child fields and mutation mechanics.
This file exists so that inventory detail has a real home without being restated in `AGENTS.md`, whose token cost every session of every fleet member pays whether or not it ever touches these files.

Read this when you have found a file in an operational home and need to identify what wrote it and whether it is yours to touch.
`AGENTS.md` section 2 names the small set of paths the always-loaded contract actually operates on; everything else below is internal to a producing script.

## Tracked code root

```
AGENTS.md            the orchestrator contract (CLAUDE.md is a symlink to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
docs/                reference documentation and backend-verification evidence
tests/               colocated shell tests
```

## Private operational home

Everything below is local and gitignored, and lives under the effective `FM_HOME`.

### `.env` and `config/`

`docs/configuration.md` owns the schema and semantics of every entry here; this list is the index only.

```
.env                 optional X-mode pairing token; presence-gates X mode (AGENTS.md section 14)
config/crew-harness  crewmate harness override; absent or "default" = same as firstmate.
                     Inherited as the literal file: a concrete primary adapter value also
                     controls a secondmate home's own crewmates
config/crew-dispatch.json  optional crewmate dispatch profiles; firstmate-maintained but
                     human-editable natural-language rules that choose a per-task
                     harness/model/effort profile. Inherited by secondmate homes
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally
                     followed by a model and effort token on the same line
                     ("<harness> [<model>] [<effort>]"); absent or "default" harness falls back
                     to config/crew-harness then firstmate's own. The primary's own setting;
                     NOT inherited into secondmate homes, because secondmates do not spawn
                     secondmates
config/backlog-backend  backlog backend override; absent or "tasks-axi" = default tasks-axi
                     backend, "manual" = force routine backlog updates to hand-editing;
                     inherited by secondmate homes
config/backend       runtime session-provider backend override for new tasks; absent = falls
                     through to runtime auto-detection (the runtime firstmate itself is
                     executing inside), then tmux. See "Runtime backend" below
config/herdr-presentation-spaces  optional presence flag for Herdr's default-off disposable
                     single-task visual projection; inherited by secondmate homes; see
                     docs/herdr-backend.md "Optional disposable single-task presentation spaces"
config/cmux-socket-password  optional cmux control-socket password; read fresh on every cmux CLI
                     call and passed through without ever overriding an operator's own ambient
                     CMUX_SOCKET_PASSWORD when absent (docs/cmux-backend.md "Setup")
config/wedge-alarm   optional away-mode wedge-alarm active-alert directives; absent means auto
                     (macOS Notification Center when available); see docs/wedge-alarm.md
config/x-mode.env    generated X-mode watcher cadence; source before arming watcher when present
```

#### Runtime backend

`tmux` is the verified reference backend (`docs/tmux-backend.md`), while `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (`docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, `docs/cmux-backend.md`).
`herdr` and `cmux` can also be selected by runtime auto-detection; `zellij` and `orca` never are and must always be explicit.
`codex-app` is not accepted as a runtime backend; see `docs/codex-app-backend.md`.
`config/backend` is not inherited into secondmate homes.

### `data/` - durable private fleet records

```
data/backlog.md      task queue, dependencies, history (AGENTS.md section 10)
data/captain.md      this home's domain-local captain preferences and working style; canonical
                     even if harness memory mirrors it, and updated with inspect-then-update
data/captain-shared.md  main-authoritative shared captain preferences propagated read-only to
                     secondmate homes; owned by the secondmate-provisioning skill
data/learnings.md    fleet-local operational facts and gotchas; dated, evidence-backed, curated,
                     and updated with inspect-then-update - rewrite and prune rather than append
                     forever, the same contract as captain.md; created lazily, absent until this
                     home has a learning to store
data/projects.md     thin fleet navigation registry; firstmate-private, parsed by
                     bin/fm-project-mode.sh
data/secondmates.md  secondmate routing table; firstmate-private, maintained by
                     bin/fm-home-seed.sh
data/<id>/brief.md   per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
data/<id>/report.md  scout task deliverable, written by the crewmate; survives teardown
```

### `projects/` - local clones

Cloned repos, gitignored, and read-only to firstmate except through the guarded exceptions listed in `AGENTS.md` section 1.

### `state/` - volatile runtime signals

The entries firstmate's always-loaded contract operates on directly are `<id>.status`, `<id>.meta`, `<id>.check.sh`, `.wake-queue`, and `.afk`.
Every other entry belongs to its producing script: read it only to identify a file you have found, and never write to, delete, or reason from it.

```
<id>.status          appended by crewmates: "<state>: <note>" wake-event lines, not
                     current-state truth; bin/fm-crew-state.sh owns current-state reconciliation
<id>.meta            written by bin/fm-spawn.sh: window=, worktree=, project=, harness=, model=,
                     effort=, kind=, mode=, yolo=, tasktmp=. kind=secondmate also records home=
                     and projects=. A non-default runtime backend records further
                     backend-specific fields (docs/configuration.md "Runtime backend";
                     bin/fm-backend.sh). bin/fm-pr-check.sh, including through
                     bin/fm-pr-merge.sh, records one canonical pr= and the forge's pr_head= when
                     available, for both GitHub pull requests and GitLab merge requests
                     (docs/gitlab-merge-watch.md). bin/fm-x-link.sh appends x_request=,
                     x_request_ts=, x_followups=, and optional x_platform=/x_reply_max_chars=
                     for an X-mode-originated task
<id>.check.sh        authenticated slow poll; the watcher dispatches validated PR data and the
                     byte-identified X shim through trusted repository scripts, runs registered
                     custom checks from hash-validated private snapshots, and rejects every other
                     state check without execution
<id>.turn-ended      touched by turn-end hooks
<id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by
                     bin/fm-teardown.sh
<id>.herdr-presentation   quarantinable attempt journal for Herdr's optional visual projection;
                     never task or endpoint authority; see docs/herdr-backend.md "Optional
                     disposable single-task presentation spaces"
<id>.check-trust     private content binding created by bin/fm-check-register.sh for an
                     intentional custom check
<id>.pr-poll         private validated data sidecar for the byte-static PR merge poll
<id>.pr-poll-registration  private transactional provenance record binding the task, canonical
                     metadata identity, sidecar, and static poll publication
.pr-check-quarantine/     private non-runnable storage for checks neutralized by the
                     non-executing migration
.pr-check-migration.log   private per-task outcomes distinguishing rebuilt or canonically
                     registered replacement polls, quarantined unarmed polls, and incomplete
                     migrations
.pr-check-migration-scan-v1  private marker proving the non-executing scan disabled every unsafe
                     legacy check; .pr-check-migration-v1 separately records completed private
                     repairs
x-watch.check.sh     generated X-mode relay poll shim; present only when opted in
x-inbox/             generated X-mode pending mention payloads; the fmx-respond skill drains it
x-context/           generated X-mode durable per-request reply context and one-wake offer
                     markers, keyed by request_id; survives inbox cleanup and expires within
                     seven days (bin/fm-x-lib.sh)
x-outbox/            generated X-mode dry-run reply and dismiss previews; inspect it when
                     FMX_DRY_RUN is set
x-poll.error x-poll.claim-error  generated X-mode relay and offer-claim diagnostic dedupe markers
.wake-queue          durable queued wakes: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
.afk                 durable away-mode flag; present = sub-supervisor may inject escalations
                     (set by /afk, cleared on captain return)
.watch.lock .wake-queue.lock   watcher singleton and queue serialization locks
.hash-* .count-* .stale-* .stale-since-* .paused-* .wedge-escalations-* .seen-* .hb-surfaced-*
.last-* .heartbeat-streak      watcher internals; never touch
.watch-triage.log    watcher's absorbed-wake debug log (size-capped); never relied on, safe to
                     delete
.last-watcher-beat   watcher liveness beacon, touched every poll (including while absorbing
                     benign wakes); guard scripts read it
.subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
```

### `.no-mistakes/`

Local validation state and evidence, gitignored.
