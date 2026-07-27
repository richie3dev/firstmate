#!/usr/bin/env bash
# Static contract tests for crew-owned no-mistakes validation runs.
# The Validate contract is owned by the task-completion skill; AGENTS.md keeps
# only the trigger stub and the safety facts that bind before it is loaded.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/task-completion/SKILL.md"

validate_contract() {
  awk '
    /^## Validate$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$SKILL"
}

test_worker_owns_synchronous_driver() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" 'The task worker that starts a no-mistakes run drives the pipeline' \
    "Validate contract does not assign the run to its initiating task worker"
  assert_contains "$contract" "owns every \`no-mistakes axi run\` and \`no-mistakes axi respond\` call through the next gate or outcome" \
    "Validate contract does not assign every synchronous driver call to the task worker"
  assert_contains "$contract" 'process every synchronous return until completion or a genuinely new escalation' \
    "Validate contract does not require the task worker to process every synchronous return"
  pass "Validate contract assigns the complete synchronous driver loop to the initiating task worker"
}

test_firstmate_never_responds_for_crew_run() {
  local contract
  contract=$(validate_contract)

  assert_contains "$contract" "Firstmate never invokes \`no-mistakes axi respond\` for a crew-owned run." \
    "Validate contract permits Firstmate to respond directly for a crew-owned run"
  pass "Validate contract forbids Firstmate from responding directly for a crew-owned run"
}

test_agents_md_keeps_the_binding_stub() {
  assert_grep 'Load `task-completion` when a no-mistakes validation run must be triggered or judged' \
    "$ROOT/AGENTS.md" "AGENTS.md lost the task-completion load trigger"
  assert_grep 'Firstmate never invokes `no-mistakes axi respond` for a crew-owned run' \
    "$ROOT/AGENTS.md" "AGENTS.md lost the inline crew-owned-run safety fact"
  assert_grep 'never answers one with `--yes`' \
    "$ROOT/AGENTS.md" "AGENTS.md lost the inline no-auto-resolve safety fact"
  pass "AGENTS.md keeps the task-completion trigger and the facts that bind before it loads"
}

test_worker_owns_synchronous_driver
test_firstmate_never_responds_for_crew_run
test_agents_md_keeps_the_binding_stub
