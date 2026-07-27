#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The authoritative file set the one owner must run, through the ShellCheck it
# resolved as the pinned version (never a bare PATH lookup at lint time).
# shellcheck disable=SC2016 # A literal source line to grep for, not an expansion.
CANON='"$SHELLCHECK_BIN" --norc bin/*.sh bin/backends/*.sh tests/*.sh'
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when fm-lint.sh can resolve exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
# Asks the one owner rather than probing PATH directly, because PATH is only one
# of the places it resolves from; provisioning is disabled so this stays a
# read-only probe that never downloads mid-test.
pinned_ready() {
  FM_LINT_NO_PROVISION=1 "$LINT" --ensure-shellcheck >/dev/null 2>&1
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  assert_grep "$CANON" "$LINT" "fm-lint.sh must run the canonical shellcheck file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  # shellcheck disable=SC2016 # A literal source line to grep for, not an expansion.
  [ "$(grep -Fc 'exec "$SHELLCHECK_BIN" --norc' "$LINT")" -eq 2 ] || fail "both lint modes must ignore ambient ShellCheck configuration"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

test_nomistakes_invokes_the_owner() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" || fail "no-mistakes commands.lint must map exactly to the one-owner script"
  pass "no-mistakes pre-push lint calls the one-owner script"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep "VERSION=\"\$(\"\$ROOT/bin/fm-lint.sh\" --required-version)\"" "$INSTALLER" "installer must read the version fm-lint.sh pins"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 2 ] || fail "both CI jobs must use the shared ShellCheck installer"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}

# A stub shellcheck that reports $1 as its version and silently passes any lint,
# so a test that "succeeds" through it proves the wrong binary was used.
write_fake_shellcheck() {
  local path=$1 version=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: $version\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$path"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  # Provisioning is disabled and the cache pointed at an empty directory, so this
  # exercises the terminal refusal rather than the self-heal path.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  write_fake_shellcheck "$fakebin/shellcheck" 0.9.9
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_NO_PROVISION=1 FM_SHELLCHECK_CACHE="$tmp/cache" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_refusal_cannot_be_mistaken_for_a_pass() {
  # The regression this guards: a refusal that reads like a skipped optional step
  # invites a hand-rolled `shellcheck -S warning` fallback, which passes work CI
  # then rejects on info-level findings. The refusal must say, in the output a
  # human or agent actually reads, that nothing was linted.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-refusal)
  fakebin=$(fm_fakebin "$tmp")
  write_fake_shellcheck "$fakebin/shellcheck" 0.9.0
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_NO_PROVISION=1 FM_SHELLCHECK_CACHE="$tmp/cache" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-pinned run exited zero, which is reportable as a pass"$'\n'"$out"
  assert_contains "$out" "REFUSING TO LINT" "the refusal must be unmistakable in its first line"
  assert_contains "$out" "NOTHING WAS LINTED" "the refusal must state that no lint ran"
  assert_contains "$out" "not a pass" "the refusal must deny that it can be read as a pass"
  assert_contains "$out" "fm-install-shellcheck.sh" "the refusal must name the exact remediation command"
  pass "a non-pinned run refuses unmistakably and never exits zero"
}

test_prefers_pinned_cache_over_wrong_path_version() {
  # The host case this fixes: the machine's own shellcheck is an older version and
  # must stay untouched, while the gate still runs at the pin from a private cache.
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): cache-over-PATH resolution check"
    return
  fi
  local tmp fakebin cache out rc real
  tmp=$(fm_test_tmproot fm-lint-cache)
  fakebin=$(fm_fakebin "$tmp")
  write_fake_shellcheck "$fakebin/shellcheck" 0.9.0
  cache="$tmp/cache"
  mkdir -p "$cache/$REQUIRED"
  real=$(FM_LINT_NO_PROVISION=1 "$LINT" --ensure-shellcheck 2>/dev/null | tail -n 1)
  cp "$real" "$cache/$REQUIRED/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_NO_PROVISION=1 FM_SHELLCHECK_CACHE="$cache" \
    "$LINT" --ensure-shellcheck 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh refused despite a pinned build in the cache"$'\n'"$out"
  assert_contains "$out" "$cache/$REQUIRED/shellcheck" "fm-lint.sh did not resolve the cached pinned build"
  pass "fm-lint.sh uses the cached pinned build when PATH holds an older shellcheck"
}

test_cache_is_version_keyed() {
  # Version keying is what makes provisioning safe while other pipelines run: a
  # pin bump writes a new path instead of overwriting a binary mid-execution.
  # shellcheck disable=SC2016 # Literal source lines to grep for, not expansions.
  assert_grep 'dir="$(cache_root)/$REQUIRED_SHELLCHECK"' "$LINT" "the ShellCheck cache path must be keyed by the pinned version"
  # shellcheck disable=SC2016 # A literal source line to grep for, not an expansion.
  assert_grep 'mv -f "$staging/shellcheck"' "$LINT" "provisioning must land the binary by atomic rename, not in-place write"
  pass "the private ShellCheck cache is version-keyed and provisioned atomically"
}

test_bootstrap_verifies_the_gate_at_session_start() {
  # Drift protection: verify at session start, not at push time when a refusal has
  # already stopped work.
  local bootstrap="$ROOT/bin/fm-bootstrap.sh"
  assert_grep 'fm-lint.sh" --ensure-shellcheck' "$bootstrap" "bootstrap must verify the pinned ShellCheck through the one owner"
  assert_grep 'MISSING: shellcheck' "$bootstrap" "bootstrap must report an unresolvable pinned ShellCheck as an actionable line"
  pass "session-start bootstrap verifies the lint gate is runnable"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_rejects_wrong_shellcheck_version
test_refusal_cannot_be_mistaken_for_a_pass
test_prefers_pinned_cache_over_wrong_path_version
test_cache_is_version_keyed
test_bootstrap_verifies_the_gate_at_session_start
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
