#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# Reproduces the permanent cleanup refusal: an investigation whose captain
# decision was answered and resolved, and then aged out of the live backlog by
# `done_keep` retention. The durably-resolved branch of the completion gate used
# to be reachable only through the live backlog, so a finished investigation
# became more certainly unclearable the longer its decisions had been settled.
seed_resolved_investigation() {  # <home> <origin-id>
  local home=$1 origin=$2 hold dep
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Investigate sample retention" --kind scout --repo sample --start >/dev/null \
    || fail "could not create retention investigation fixture"
  write_origin_meta "$home" "$origin"
  printf 'needs-decision [key=route]: choose route north or route south\ndone: report complete\n' \
    > "$home/state/$origin.status"
  printf '# Sample retention review\n\nOne captain choice was surfaced and answered.\n' \
    > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register the retention route hold"
  run_decisions "$home" complete "$origin" route >/dev/null \
    || fail "completion gate failed while the decision was held"
  dep="$origin-implementation"
  tasks_in "$home" add "$dep" "Apply the selected sample route" --kind ship --repo sample \
    --blocked-by "$hold" >/dev/null || fail "could not route dependent work behind the hold"
  printf 'Use route north for the sample system.\n' > "$home/$origin-decision.txt"
  run_decisions "$home" resolve "$origin" route --decision-file "$home/$origin-decision.txt" \
    --routed-to "$dep" >/dev/null || fail "could not resolve the retention captain decision"
  printf '%s\n' "$hold"
}

test_archived_resolution_still_passes_the_completion_gate() {
  local home origin hold
  home=$(make_home archived-resolution)
  origin=sample-retention-review
  hold=$(seed_resolved_investigation "$home" "$origin")
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "verification failed while the resolution was still in the live backlog"

  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  ! grep -F "$hold" "$home/data/backlog.md" >/dev/null \
    || fail "retention fixture left the resolved decision in the live backlog"
  grep -F "$hold" "$home/data/done-archive.md" >/dev/null \
    || fail "retention fixture did not archive the resolved decision"

  run_decisions "$home" verify "$origin" >/dev/null 2> "$home/archived-verify.err" \
    || fail "archived resolution failed the completion gate: $(cat "$home/archived-verify.err")"
  run_decisions "$home" resolve "$origin" route --decision-file "$home/$origin-decision.txt" \
    --routed-to "$origin-implementation" >/dev/null 2> "$home/archived-resolve.err" \
    || fail "resolution retry stopped being idempotent after archival: $(cat "$home/archived-resolve.err")"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/archived-teardown.err" \
    || fail "archived resolution blocked investigation cleanup: $(cat "$home/archived-teardown.err")"
  assert_absent "$home/state/$origin.meta" "cleared investigation kept its durable record"
  pass "a resolved decision keeps passing the completion gate after retention archives it"
}

# The archive path is a per-home configuration choice. Reading a hard-coded
# data/done-archive.md would silently do nothing for a home that configured
# another path, which is the same defect wearing a different hat.
test_archive_lookup_follows_the_configured_archive_path() {
  local home origin hold
  home=$(make_home configured-archive-path)
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/decision-archive.md"
done_keep = 10
EOF
  origin=sample-configured-archive-review
  hold=$(seed_resolved_investigation "$home" "$origin")
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  grep -F "$hold" "$home/data/decision-archive.md" >/dev/null \
    || fail "retention fixture did not use the configured archive path"
  [ ! -e "$home/data/done-archive.md" ] || fail "fixture wrote the default archive path"
  run_decisions "$home" verify "$origin" >/dev/null 2> "$home/configured-verify.err" \
    || fail "completion gate ignored the configured archive: $(cat "$home/configured-verify.err")"
  pass "the durable-decision lookup reads the archive the home actually configured"
}

# The archive is a wider view, never a lower bar. Each of these is a decision the
# gate must still refuse, and all three are indistinguishable from a resolved one
# unless the archived record itself is inspected.
test_archive_lookup_refuses_unregistered_open_and_unresolved_decisions() {
  local home origin hold
  home=$(make_home unregistered-decision)
  origin=sample-ghost-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Ghost decision review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create ghost-decision origin"
  write_origin_meta "$home" "$origin"
  printf 'decisions_reviewed=1\ndecision_keys=ghost\n' >> "$home/state/$origin.meta"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Ghost review\n\nThe inventory names a decision that was never registered.\n' \
    > "$home/data/$origin/report.md"
  if run_decisions "$home" verify "$origin" > "$home/ghost.out" 2> "$home/ghost.err"; then
    fail "verification accepted a decision key with no backlog record anywhere"
  fi
  assert_grep "is absent from" "$home/ghost.err" "an unregistered decision must refuse as absent"
  if run_teardown "$home" "$origin" >/dev/null 2> "$home/ghost-teardown.err"; then
    fail "cleanup erased an investigation whose decision was never registered"
  fi
  assert_present "$home/state/$origin.meta" "refused cleanup removed investigation metadata"

  home=$(make_home archived-open-decision)
  origin=sample-archived-open-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Archived open decision review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-open origin"
  write_origin_meta "$home" "$origin"
  printf 'decisions_reviewed=1\ndecision_keys=open\n' >> "$home/state/$origin.meta"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Archived open review\n\nAn unanswered decision was filed into the archive.\n' \
    > "$home/data/$origin/report.md"
  cat > "$home/data/done-archive.md" <<EOF

## Archived 2026-07-14
- [ ] $origin-decision-open - Choose the sample gauge (repo: sample) (kind: captain) (hold-kind: captain)
  Origin: $origin
  Decision key: open
  State: awaiting captain decision.
EOF
  if run_decisions "$home" verify "$origin" > "$home/open.out" 2> "$home/open.err"; then
    fail "verification accepted a still-open decision parked in the archive"
  fi
  assert_grep "neither actively held nor durably resolved" "$home/open.err" \
    "an open archived decision must refuse as unresolved"

  pass "unregistered and still-open archived decisions both still refuse"
}

# An inventoried captain decision the captain never answered. The caller closes
# it with a plain `tasks-axi done`, which keeps the unanswered body the hold was
# created with, and archives it.
seed_unanswered_decision() {  # <home> <origin-id> <decision-key>
  local home=$1 origin=$2 key=$3 hold
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Unanswered decision review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unanswered-decision origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Unanswered decision review\n\nThe decision was closed outside the durable path.\n' \
    > "$home/data/$origin/report.md"
  hold=$(run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the sample $key" --reason "captain $key choice pending" --repo sample) \
    || fail "could not register the $key hold"
  run_decisions "$home" complete "$origin" "$key" >/dev/null \
    || fail "completion gate failed while the $key decision was held"
  printf '%s\n' "$hold"
}

# A closed captain hold is not an answered one. A decision closed with a plain
# `tasks-axi done` keeps the unanswered body it was created with, and retention
# then archives it looking exactly like a resolved decision from the outside.
# Widening the lookup to the archive must not turn that into a pass: the captain
# never answered, so the investigation that surfaced it must stay parked.
test_archived_unanswered_decision_still_refuses() {
  local home origin hold record
  home=$(make_home archived-unanswered-decision)
  origin=sample-archived-closed-review
  hold=$(seed_unanswered_decision "$home" "$origin" gauge)

  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the hold outside the durable path"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  grep -F "$hold" "$home/data/done-archive.md" >/dev/null \
    || fail "fixture did not archive the bypassed hold"
  record=$(bash -c '. "$1"; fm_tasks_axi_archive_show "$2" "$3"' _ \
    "$ROOT/bin/fm-tasks-axi-lib.sh" "$home" "$hold") \
    || fail "the archived bypassed hold could not be read back"
  assert_contains "$record" "state: done" "the bypassed hold must archive as closed"
  assert_contains "$record" "State: awaiting captain decision." \
    "the bypassed hold must keep its unanswered body, which is what the gate reads"

  if run_decisions "$home" verify "$origin" > "$home/closed.out" 2> "$home/closed.err"; then
    fail "verification accepted an archived decision the captain never answered"
  fi
  assert_grep "neither actively held nor durably resolved" "$home/closed.err" \
    "an archived decision without the resolution record must refuse"
  if run_teardown "$home" "$origin" >/dev/null 2> "$home/closed-teardown.err"; then
    fail "cleanup erased an investigation whose decision the captain never answered"
  fi
  assert_grep "REFUSED" "$home/closed-teardown.err" "the cleanup refusal must be explicit"
  assert_present "$home/state/$origin.meta" "refused cleanup removed investigation metadata"
  assert_present "$home/data/$origin/report.md" "refused cleanup removed the investigation report"
  pass "an archived decision closed without an answer still refuses cleanup"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# A hold identity is composed as <origin-id>-decision-<decision-key>, and two
# investigations can compose the same string, so the identity alone never proves
# a record answers for the origin asking. Reaching into the archive would
# otherwise hand one investigation's settled answer to another and let teardown
# erase a source whose own captain decision is genuinely unanswered.
test_a_resolution_answers_only_the_origin_it_names() {
  local home first second hold other_hold dep
  home=$(make_home borrowed-resolution)
  first=sample-shared-review
  second=sample-shared-review-decision-route
  hold="$first-decision-route-decision-north"
  [ "$(run_decisions "$home" id "$first" route-decision-north)" = "$hold" ] \
    || fail "the first investigation's hold identity was not the fixture identity"
  [ "$(run_decisions "$home" id "$second" north)" = "$hold" ] \
    || fail "the fixture investigations do not compose the same hold identity"

  mkdir -p "$home/data/$first"
  tasks_in "$home" add "$first" "Shared identity review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answering investigation"
  write_origin_meta "$home" "$first"
  printf 'done: report complete\n' > "$home/state/$first.status"
  printf '# Shared identity review\n\nThe captain answered this one.\n' > "$home/data/$first/report.md"
  other_hold=$(run_decisions "$home" hold "$first" route-decision-north \
    --title "Choose the shared sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register the answering hold"
  [ "$other_hold" = "$hold" ] || fail "the registered hold left the fixture identity: $other_hold"
  run_decisions "$home" complete "$first" route-decision-north >/dev/null \
    || fail "completion gate failed while the shared decision was held"
  dep="$first-implementation"
  tasks_in "$home" add "$dep" "Apply the shared sample route" --kind ship --repo sample \
    --blocked-by "$hold" >/dev/null || fail "could not route dependent work behind the shared hold"
  printf 'Use route north for the shared sample system.\n' > "$home/shared-decision.txt"
  run_decisions "$home" resolve "$first" route-decision-north \
    --decision-file "$home/shared-decision.txt" --routed-to "$dep" >/dev/null \
    || fail "could not resolve the answering investigation's decision"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  grep -F "Origin: $first" "$home/data/done-archive.md" >/dev/null \
    || fail "the archived resolution did not record the origin it answered for"

  mkdir -p "$home/data/$second"
  tasks_in "$home" add "$second" "Borrowing identity review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the borrowing investigation"
  write_origin_meta "$home" "$second"
  printf 'done: report complete\n' > "$home/state/$second.status"
  printf '# Borrowing identity review\n\nThis captain decision was never answered.\n' \
    > "$home/data/$second/report.md"
  if run_decisions "$home" complete "$second" north > "$home/borrowed.out" 2> "$home/borrowed.err"; then
    fail "completion inherited another investigation's archived answer"
  fi
  assert_grep "answered for another origin" "$home/borrowed.err" \
    "a borrowed resolution must refuse by naming the provenance mismatch"
  assert_no_grep "decisions_reviewed=1" "$home/state/$second.meta" \
    "refused completion recorded a false completion attestation"

  printf 'decisions_reviewed=1\ndecision_keys=north\n' >> "$home/state/$second.meta"
  if run_decisions "$home" verify "$second" > "$home/borrowed-verify.out" 2> "$home/borrowed-verify.err"; then
    fail "verification inherited another investigation's archived answer"
  fi
  assert_grep "answered for another origin" "$home/borrowed-verify.err" \
    "a borrowed resolution must refuse verification too"
  if run_teardown "$home" "$second" >/dev/null 2> "$home/borrowed-teardown.err"; then
    fail "cleanup erased a source whose captain decision was answered for another origin"
  fi
  assert_grep "REFUSED" "$home/borrowed-teardown.err" "the cleanup refusal must be explicit"
  assert_present "$home/state/$second.meta" "refused cleanup removed investigation metadata"
  pass "an archived resolution answers only the origin it names"
}

# Every resolution recorded before origins were written carries no origin line.
# Requiring one would make each already-resolved decision start refusing, which
# is the permanent refusal this lookup exists to end, so a record that names no
# origin must keep passing.
test_a_resolution_without_a_recorded_origin_still_passes() {
  local home origin hold archive
  home=$(make_home originless-resolution)
  origin=sample-legacy-resolution-review
  hold=$(seed_resolved_investigation "$home" "$origin")
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  archive="$home/data/done-archive.md"
  grep -F "Origin: $origin" "$archive" >/dev/null \
    || fail "the archived resolution did not record an origin to strip"
  grep -v "^  Origin: " "$archive" > "$archive.legacy" \
    || fail "could not build the pre-origin resolution fixture"
  mv "$archive.legacy" "$archive"
  assert_no_grep "Origin: " "$archive" "the fixture must carry no origin line at all"
  grep -F "$hold" "$archive" >/dev/null || fail "the fixture lost the archived resolution"
  run_decisions "$home" verify "$origin" >/dev/null 2> "$home/legacy-verify.err" \
    || fail "a resolution recorded before origins were written refused: $(cat "$home/legacy-verify.err")"
  run_teardown "$home" "$origin" >/dev/null 2> "$home/legacy-teardown.err" \
    || fail "a resolution recorded before origins were written blocked cleanup: $(cat "$home/legacy-teardown.err")"
  pass "a resolution that names no origin keeps passing the completion gate"
}

# An answer must stay recordable for as long as the decision matters. A hold
# closed outside `resolve` keeps its unanswered body, retention archives it, and
# `resolve` reached the hold through the live backlog only - so the one command
# that records the captain's answer refused permanently and the investigation
# stayed parked forever. Widening that lookup must not widen what `resolve`
# accepts: the routed work still has to exist and be durably blocked by the hold.
test_resolve_records_an_answer_after_retention_archives_the_hold() {
  local home origin hold dep show
  home=$(make_home archived-resolve)
  origin=sample-archived-answer-review
  hold=$(seed_unanswered_decision "$home" "$origin" gauge)
  dep="$origin-implementation"
  tasks_in "$home" add "$dep" "Apply the selected sample gauge" --kind ship --repo sample \
    --blocked-by "$hold" >/dev/null || fail "could not route dependent work behind the hold"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the hold outside the durable path"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  ! grep -E "^- \[[ x]\] $hold -" "$home/data/backlog.md" >/dev/null \
    || fail "retention fixture left the closed hold in the live backlog"
  if run_decisions "$home" verify "$origin" > "$home/unanswered.out" 2> "$home/unanswered.err"; then
    fail "the gate accepted an archived decision before the captain answered it"
  fi

  printf 'Use the wide sample gauge.\n' > "$home/gauge-decision.txt"
  run_decisions "$home" resolve "$origin" gauge --decision-file "$home/gauge-decision.txt" \
    --routed-to "$dep" >/dev/null 2> "$home/archived-answer.err" \
    || fail "an answer could not be recorded against an archived hold: $(cat "$home/archived-answer.err")"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the answered hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" \
    "the answered hold did not keep the durable resolution record"
  assert_contains "$show" "Origin: $origin" "the recorded answer did not name its origin"
  show=$(tasks_in "$home" show "$dep" --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release the routed work"
  run_decisions "$home" verify "$origin" >/dev/null 2> "$home/answered-verify.err" \
    || fail "the recorded answer did not satisfy the gate: $(cat "$home/answered-verify.err")"
  run_decisions "$home" resolve "$origin" gauge --decision-file "$home/gauge-decision.txt" \
    --routed-to "$dep" >/dev/null 2> "$home/answered-retry.err" \
    || fail "the recorded answer was not idempotent: $(cat "$home/answered-retry.err")"

  pass "an answer stays recordable after retention archives its captain hold"
}

# A command that fails must not change the gate's verdict. Restoring an archived
# hold is a durable write, so a resolve that later refuses - a mistyped
# --routed-to, work the hold never blocked - would otherwise leave the decision
# resurrected as an actively held item, which the gate accepts, and teardown
# would erase a source whose captain decision is still unanswered. A refused
# resolution must leave the backlog, the archive, and the verdict untouched.
test_a_refused_resolution_leaves_an_archived_hold_untouched() {
  local home origin hold unrouted before after
  home=$(make_home archived-resolve-strict)
  origin=sample-archived-strict-review
  hold=$(seed_unanswered_decision "$home" "$origin" depth)
  unrouted="$origin-unrouted"
  tasks_in "$home" add "$unrouted" "Sample work the decision never blocked" --kind ship --repo sample >/dev/null \
    || fail "could not create the unrouted control task"
  tasks_in "$home" "done" "$hold" >/dev/null || fail "could not close the strict hold outside the durable path"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention to the strict fixture"
  if run_decisions "$home" verify "$origin" > "$home/before.out" 2> "$home/before.err"; then
    fail "the gate accepted the unanswered decision before any resolution was attempted"
  fi
  before=$(cat "$home/data/backlog.md" "$home/data/done-archive.md" | shasum -a 256 | awk '{print $1}')

  printf 'Use the deep sample setting.\n' > "$home/depth-decision.txt"
  if run_decisions "$home" resolve "$origin" depth --decision-file "$home/depth-decision.txt" \
    --routed-to sample-absent-implementation > "$home/strict.out" 2> "$home/strict.err"; then
    fail "resolve against an archived hold accepted routed work that does not exist"
  fi
  assert_grep "does not exist in the active home" "$home/strict.err" \
    "an archived hold must still require its routed work to exist"
  if run_decisions "$home" resolve "$origin" depth --decision-file "$home/depth-decision.txt" \
    --routed-to "$unrouted" > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "resolve against an archived hold accepted work it never blocked"
  fi
  assert_grep "not durably blocked by" "$home/unrouted.err" \
    "an archived hold must still require its routed work to be blocked by it"

  after=$(cat "$home/data/backlog.md" "$home/data/done-archive.md" | shasum -a 256 | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a refused resolution changed durable backlog state"
  ! grep -E "^- \[[ x]\] $hold -" "$home/data/backlog.md" >/dev/null \
    || fail "a refused resolution resurrected the archived hold into the live backlog"
  if run_decisions "$home" verify "$origin" > "$home/after.out" 2> "$home/after.err"; then
    fail "a refused resolution flipped the gate into accepting an unanswered decision"
  fi
  assert_grep "neither actively held nor durably resolved" "$home/after.err" \
    "the verdict after a refused resolution must be the verdict before it"
  if run_teardown "$home" "$origin" >/dev/null 2> "$home/strict-teardown.err"; then
    fail "a refused resolution let cleanup erase a source whose decision is unanswered"
  fi
  assert_grep "REFUSED" "$home/strict-teardown.err" "the cleanup refusal must be explicit"
  assert_present "$home/state/$origin.meta" "refused cleanup removed investigation metadata"
  assert_present "$home/data/$origin/report.md" "refused cleanup removed the investigation report"
  pass "a refused resolution leaves an archived hold, and the gate's verdict, untouched"
}

# The archive path is per-home configuration. tasks-axi honours TOML literal
# strings as readily as double-quoted ones, and a home with no .tasks.toml still
# archives, because tasks-axi does not walk up to a parent config. Reading either
# as "this home has no archive" silently reinstates the permanent refusal there.
test_archive_lookup_reads_literal_string_and_default_archive_paths() {
  local home origin hold
  home=$(make_home literal-archive-path)
  cat > "$home/.tasks.toml" <<'EOF'
backend = 'markdown'

[markdown]
path = 'data/backlog.md'
archive = 'data/literal-archive.md'
done_keep = 10
EOF
  origin=sample-literal-archive-review
  hold=$(seed_resolved_investigation "$home" "$origin")
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  grep -F "$hold" "$home/data/literal-archive.md" >/dev/null \
    || fail "retention fixture did not use the literal-string archive path"
  run_decisions "$home" verify "$origin" >/dev/null 2> "$home/literal-verify.err" \
    || fail "the gate ignored a literal-string archive path: $(cat "$home/literal-verify.err")"

  home=$(make_home default-archive-path)
  rm -f "$home/.tasks.toml" "$home/data/backlog.md"
  origin=sample-default-archive-review
  hold=$(seed_resolved_investigation "$home" "$origin")
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not apply backlog retention"
  grep -F "$hold" "$home/done-archive.md" >/dev/null \
    || fail "a home with no config did not archive into the tasks-axi default"
  [ ! -e "$home/data/done-archive.md" ] || fail "the no-config fixture archived into a configured path"
  run_decisions "$home" verify "$origin" >/dev/null 2> "$home/default-verify.err" \
    || fail "the gate refused a home that has no .tasks.toml: $(cat "$home/default-verify.err")"
  pass "the archive lookup reads literal-string and defaulted archive paths"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_archived_resolution_still_passes_the_completion_gate
test_archive_lookup_follows_the_configured_archive_path
test_archive_lookup_refuses_unregistered_open_and_unresolved_decisions
test_archived_unanswered_decision_still_refuses
test_archive_lookup_reads_literal_string_and_default_archive_paths
test_a_resolution_answers_only_the_origin_it_names
test_a_resolution_without_a_recorded_origin_still_passes
test_resolve_records_an_answer_after_retention_archives_the_hold
test_a_refused_resolution_leaves_an_archived_hold_untouched
