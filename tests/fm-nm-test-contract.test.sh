#!/usr/bin/env bash
# Contract: local no-mistakes Test is intent-targeted; CI owns broad regression.
#
# Firstmate must not configure commands.test as a complete tests/*.test.sh walk
# (that duplicated CI and burned local pipeline time). Lint stays pinned to
# bin/fm-lint.sh. Remote CI Behavior must keep iterating every tests/*.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
CI="$ROOT/.github/workflows/ci.yml"

test_nm_yaml_tracked() {
  assert_present "$NM" "tracked .no-mistakes.yaml is missing"
  git -C "$ROOT" ls-files --error-unmatch .no-mistakes.yaml >/dev/null 2>&1 \
    || fail ".no-mistakes.yaml is not tracked by git"
  pass ".no-mistakes.yaml is present and tracked"
}

test_nm_keeps_lint_pin() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" \
    || fail "commands.lint must remain exactly bin/fm-lint.sh"
  pass "commands.lint stays pinned to bin/fm-lint.sh"
}

# True when the YAML maps a non-empty commands.test (string or mapping value).
# Empty / null / absent is the intended targeted-Test posture.
nm_commands_test_value() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c '
import yaml, sys
doc = yaml.safe_load(open(sys.argv[1])) or {}
cmds = doc.get("commands") or {}
val = cmds.get("test") if isinstance(cmds, dict) else None
if val is None or val is False:
    print("")
elif isinstance(val, str):
    print(val)
else:
    print(repr(val))
' "$NM"
    return
  fi
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e '
doc = YAML.safe_load(File.read(ARGV[0])) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
if val.nil? || val == false
  puts ""
elsif val.is_a?(String)
  puts val
else
  puts val.inspect
end
' "$NM"
    return
  fi
  # Structural fallback: any commands.test line under the commands block.
  awk '
    /^commands:[[:space:]]*$/ { in_cmds=1; next }
    in_cmds && /^[^[:space:]#]/ { in_cmds=0 }
    in_cmds && /^[[:space:]]+test:[[:space:]]*/ {
      sub(/^[[:space:]]+test:[[:space:]]*/, "")
      gsub(/^['\''"]|['\''"]$/, "")
      print
      exit
    }
  ' "$NM"
}

test_nm_has_no_complete_local_test_command() {
  local val
  val=$(nm_commands_test_value) || fail "failed to read commands.test from .no-mistakes.yaml"
  if [ -n "$val" ]; then
    case "$val" in
      *'tests/*.test.sh'*|*'tests/'*'.test.sh'*)
        fail "commands.test must not walk the complete tests/*.test.sh suite; got: $val"
        ;;
      *)
        # Any non-empty override still steers Test away from intent-targeted default.
        fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
        ;;
    esac
  fi
  # Also refuse a commented-out full-suite remnant that could be re-enabled by habit.
  if grep -E '^[[:space:]]*#?[[:space:]]*test:[[:space:]].*tests/\*\.test\.sh' "$NM" >/dev/null 2>&1; then
    fail ".no-mistakes.yaml still documents a full-suite commands.test line (active or comment)"
  fi
  pass "no-mistakes does not configure a complete local Test command"
}

test_ci_still_runs_broad_behavior_suite() {
  assert_present "$CI" "ci.yml is missing"
  # Behavior job still iterates every portable behavior script.
  grep -Fq 'for test_script in tests/*.test.sh' "$CI" \
    || fail "CI Behavior job must still loop over tests/*.test.sh"
  grep -Fq "\"\$test_script\"" "$CI" \
    || fail "CI Behavior job must still execute each tests/*.test.sh script"
  # Preserve other CI lanes this task must not shrink.
  grep -Eq 'name:[[:space:]]*Lint shell scripts' "$CI" \
    || fail "CI must retain the lint job"
  grep -Eq 'name:[[:space:]]*Stock macOS Bash snapshot compatibility' "$CI" \
    || fail "CI must retain the macOS stock Bash compatibility job"
  grep -Eq 'name:[[:space:]]*Repo invariants' "$CI" \
    || fail "CI must retain the repo invariants job"
  pass "CI still owns the broad behavior suite and companion jobs"
}

# The serial suite outgrew its wall clock and CI cancelled it mid-run, which
# reads as a red check for a suite that was actually passing. Sharding fixes
# that only while the partition stays complete and disjoint: a selector bug
# would silently stop running some scripts and still report every shard green,
# which is worse than the timeout it replaced.
test_ci_behavior_shards_cover_every_script_exactly_once() {
  local shard_total position selected index script
  assert_present "$CI" "ci.yml is missing"
  grep -Eq '^        shard: \[1, 2, 3, 4\]$' "$CI" \
    || fail "CI Behavior job must shard over an explicit matrix"
  grep -Eq '^      fail-fast: false$' "$CI" \
    || fail "CI Behavior shards must all report; fail-fast would hide sibling failures"
  shard_total=$(sed -n 's/^          SHARD_TOTAL: \([0-9]\{1,\}\)$/\1/p' "$CI")
  [ -n "$shard_total" ] || fail "CI Behavior job must declare SHARD_TOTAL"
  [ "$shard_total" -eq 4 ] \
    || fail "SHARD_TOTAL ($shard_total) must match the 4-entry shard matrix"

  # Replay the workflow's own round-robin selector over the real inventory.
  selected=""
  for index in $(seq 1 "$shard_total"); do
    position=0
    for script in "$ROOT"/tests/*.test.sh; do
      position=$((position + 1))
      [ "$(((position - 1) % shard_total + 1))" -eq "$index" ] || continue
      selected="$selected$script"$'\n'
    done
  done
  [ "$(printf '%s' "$selected" | grep -c .)" -eq "$(ls "$ROOT"/tests/*.test.sh | wc -l)" ] \
    || fail "sharded selection does not cover every tests/*.test.sh exactly once"
  [ -z "$(printf '%s' "$selected" | sort | uniq -d)" ] \
    || fail "sharded selection runs at least one script in more than one shard"
  pass "CI behavior shards partition every test script exactly once"
}

test_nm_yaml_tracked
test_nm_keeps_lint_pin
test_nm_has_no_complete_local_test_command
test_ci_still_runs_broad_behavior_suite
test_ci_behavior_shards_cover_every_script_exactly_once
