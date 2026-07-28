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

# This suite owns real lint behavior, so it must resolve the machine's ACTUAL
# pinned build rather than tests/lib.sh's hermetic stub cache (which exists so the
# suites that merely run bootstrap never download one). Cases that need a
# controlled cache set FM_SHELLCHECK_CACHE themselves.
unset FM_SHELLCHECK_CACHE

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
  assert_grep "ACTUAL_SHA256=\$(file_sha256" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
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
  # macOS ships no GNU timeout, so a bare `timeout` fails with 127 there and would
  # report the pinned build absent on a host that has it - a fresh local/CI
  # disagreement of exactly the kind this gate exists to remove.
  assert_grep 'gtimeout 120' "$bootstrap" "bootstrap must bound the check with the repo's portable timeout fallback"
  pass "session-start bootstrap verifies the lint gate is runnable"
}

test_bootstrap_remediation_is_real_and_agrees_with_the_refusal() {
  # `fm-bootstrap.sh install <tool>` evals this string, and a developer reads it
  # off the MISSING line, so it must parse as a command and must send them to the
  # same place fm-lint.sh's own refusal does.
  local bootstrap="$ROOT/bin/fm-bootstrap.sh" cmd
  cmd=$(sed -n 's/^ *shellcheck) echo "\(.*\)" ;;$/\1/p' "$bootstrap")
  [ -n "$cmd" ] || fail "bootstrap has no shellcheck install_cmd entry"
  cmd=${cmd%%  #*}
  bash -n -c "$cmd" 2>/dev/null || fail "bootstrap's shellcheck install_cmd does not parse as a command: $cmd"
  assert_grep "$cmd" "$LINT" "fm-lint.sh's refusal must name the same remediation bootstrap prints"
  pass "the shellcheck remediation is evaluable and identical in both owners"
}

test_installer_bounds_its_download() {
  # The lint gate now reaches the installer automatically, so an unbounded fetch
  # would hang the gate silently instead of landing on the refusal path.
  assert_grep '--connect-timeout' "$INSTALLER" "the installer must bound connection setup"
  assert_grep '--max-time' "$INSTALLER" "the installer must bound the whole download"
  pass "the pinned-build download is bounded"
}

# --- platform binding -------------------------------------------------------
#
# The installer used to hardcode one linux.x86_64 asset, so on an arm64 Linux or
# any macOS it could not provision the pin at all and fm-lint.sh refused - the
# whole lint gate offline on that machine, which is exactly the CI-only-lint
# state the pin exists to prevent. The cases below exercise selection and
# refusal for every platform from one machine and download nothing: --print-asset
# resolves and exits, and FM_SHELLCHECK_UNAME_S/M simulate the machine.

# Every uname pair the installer claims, and the upstream platform token each
# must resolve to. Kept here as the test's own expectation so a silent edit to
# the script's matrix cannot also edit what is asserted about it.
CLAIMED_PLATFORMS='Linux x86_64 linux.x86_64
Linux amd64 linux.x86_64
Linux aarch64 linux.aarch64
Linux arm64 linux.aarch64
Linux armv6l linux.armv6hf
Linux armv7l linux.armv6hf
Linux armv8l linux.armv6hf
Linux riscv64 linux.riscv64
Darwin x86_64 darwin.x86_64
Darwin arm64 darwin.aarch64
Darwin aarch64 darwin.aarch64'

# Machines upstream publishes no asset for at this version, so the installer
# must refuse rather than guess something adjacent.
UNCLAIMED_PLATFORMS='Linux i686
Linux ppc64le
Linux s390x
Darwin i386
FreeBSD amd64
SunOS i86pc'

print_asset_for() {
  FM_SHELLCHECK_UNAME_S=$1 FM_SHELLCHECK_UNAME_M=$2 "$INSTALLER" --print-asset 2>&1
}

asset_field() {
  printf '%s\n' "$1" | awk -v key="$2:" '$1 == key { print $2 }'
}

test_installer_selects_an_asset_per_claimed_platform() {
  local os arch token out archive sha
  while read -r os arch token; do
    out=$(print_asset_for "$os" "$arch") \
      || fail "installer refused a claimed platform ($os/$arch)"$'\n'"$out"
    archive=$(asset_field "$out" archive)
    sha=$(asset_field "$out" sha256)
    [ "$archive" = "shellcheck-v$REQUIRED.$token.tar.gz" ] \
      || fail "$os/$arch resolved to '$archive', expected the $token asset for the pinned version"
    # A checksum is what makes a claim honest, so an empty or malformed one is a
    # failure even though the selection looked right.
    printf '%s\n' "$sha" | grep -Eq '^[0-9a-f]{64}$' \
      || fail "$os/$arch carries no valid sha256 ('$sha')"
    assert_contains "$out" "/releases/download/v$REQUIRED/$archive" \
      "$os/$arch must resolve the upstream URL for its own asset"
  done <<CLAIMED
$CLAIMED_PLATFORMS
CLAIMED
  pass "the installer resolves a checksummed asset for every claimed platform"
}

test_installer_never_falls_through_to_another_architecture() {
  # The defect this replaces was silent: every machine got the x86_64 asset. A
  # fallthrough would reappear as two different architectures sharing one
  # checksum, so distinctness is the property worth asserting.
  local os arch token out pair seen=
  while read -r os arch token; do
    out=$(print_asset_for "$os" "$arch") || fail "installer refused a claimed platform ($os/$arch)"
    pair="$token $(asset_field "$out" sha256)"
    case "$seen" in
      *"$pair"*) : ;;
      *)
        # A checksum already bound to a DIFFERENT token means two architectures
        # resolved to the same bytes.
        case "$seen" in
          *"$(asset_field "$out" sha256)"*)
            fail "$os/$arch ($token) reuses the checksum of another architecture"
            ;;
        esac
        seen="$seen$pair"$'\n'
        ;;
    esac
  done <<CLAIMED
$CLAIMED_PLATFORMS
CLAIMED
  pass "each architecture resolves its own asset, never another's"
}

test_installer_refuses_unclaimed_architectures_by_name() {
  local os arch out rc tmp fakebin
  tmp=$(fm_test_tmproot fm-lint-arch)
  fakebin=$(fm_fakebin "$tmp")
  # A curl that records being called, so "refused before any download" is
  # asserted rather than assumed from where the check sits in the script.
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf 'called\n' >> '$tmp/curl-was-called'
exit 1
SH
  chmod +x "$fakebin/curl"
  while read -r os arch; do
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_SHELLCHECK_UNAME_S="$os" FM_SHELLCHECK_UNAME_M="$arch" \
      "$INSTALLER" "$tmp/never" 2>&1) || rc=$?
    expect_code 1 "$rc" "installer must refuse $os/$arch"
    assert_contains "$out" "REFUSING" "the $os/$arch refusal must read as a refusal"
    # By name: the message must print what it detected, not a generic failure.
    assert_contains "$out" "uname -s=$os" "the refusal must name the detected OS"
    assert_contains "$out" "uname -m=$arch" "the refusal must name the detected architecture"
    # And what a human can do about it.
    assert_contains "$out" "claimed platforms are" "the refusal must name what IS supported"
    assert_contains "$out" "releases/tag/v$REQUIRED" "the refusal must point at the upstream asset list"
    assert_contains "$out" "PATH" "the refusal must offer the PATH route fm-lint.sh resolves first"
    assert_absent "$tmp/never" "a refused platform must not create a destination"
  done <<UNCLAIMED
$UNCLAIMED_PLATFORMS
UNCLAIMED
  assert_absent "$tmp/curl-was-called" "an unclaimed platform must refuse before downloading anything"
  pass "unclaimed architectures refuse by name with an actionable message"
}

test_installer_separates_provenance_from_runtime_evidence() {
  # A published checksum proves the bytes are upstream's. It does not prove the
  # binary RUNS on that architecture; only executing it there does, and this
  # project owns no arm64, armv6hf, riscv64, or macOS hardware. Those are
  # different claims and the installer must not let one pass for the other.
  local os arch token out evidence
  while read -r os arch token; do
    out=$(print_asset_for "$os" "$arch") || fail "installer refused a claimed platform ($os/$arch)"
    evidence=$(asset_field "$out" evidence)
    case "$evidence" in
      runtime-verified)
        [ "$token" = linux.x86_64 ] \
          || fail "$token claims runtime-verified, but no $token hardware has run this build"
        ;;
      checksum-only) : ;;
      *) fail "$os/$arch states no evidence level for its checksum (got '$evidence')" ;;
    esac
  done <<CLAIMED
$CLAIMED_PLATFORMS
CLAIMED
  # The distinction has to survive in the script a future editor reads, not only
  # in this suite.
  assert_grep 'checksum-only' "$INSTALLER" "the installer must record which assets are backed by provenance alone"
  assert_grep 'runtime-verified' "$INSTALLER" "the installer must record which assets have actually been executed"
  pass "each asset states whether its evidence is provenance or a real run"
}

test_installer_hashes_without_gnu_coreutils() {
  # sha256sum is GNU coreutils and is absent from a stock macOS, so selecting the
  # right asset while still hashing with sha256sum leaves macOS broken one line
  # later. shasum is preinstalled there; this is the ordering the rest of
  # firstmate's scripts already use.
  # Read the hashing function itself, not the whole file: the header explains
  # both tools, so a file-wide match would pass on prose alone.
  local body first
  body=$(sed -n '/^file_sha256() {/,/^}/p' "$INSTALLER")
  [ -n "$body" ] || fail "the installer must keep its checksum step in one readable file_sha256 function"
  assert_contains "$body" "shasum -a 256" "the installer must try shasum, which stock macOS has"
  assert_contains "$body" "sha256sum" "the installer must still accept GNU coreutils where that is what exists"
  # ERE, not `\|`: BSD grep (macOS /usr/bin/grep) has no BRE alternation and
  # would search for the literal string "shasum -a 256|sha256sum", match nothing,
  # and fail this case on the one platform the change exists to unblock.
  first=$(printf '%s\n' "$body" | grep -Eo 'shasum -a 256|sha256sum' | head -1)
  [ "$first" = "shasum -a 256" ] \
    || fail "the installer must try shasum BEFORE sha256sum, or macOS still fails at the checksum"$'\n'"$body"
  # No hasher at all must refuse, never install an unhashed download.
  assert_grep 'no SHA-256 tool found' "$INSTALLER" "a machine with no hasher must refuse rather than skip the checksum"
  pass "the checksum step works on a machine without GNU coreutils"
}

test_installer_separates_a_broken_hasher_from_a_bad_download() {
  # `hasher | awk` reports awk's status, so a hasher that fails hands back an
  # empty digest at exit 0. That never equals a 64-hex checksum, so the install
  # is still refused - but refused as a checksum mismatch, which sends the reader
  # after the download instead of the broken tool. Run both hasher failures for
  # real, because the distinction is in the exit paths, not in the prose.
  local tmp curlbin badhasher base out rc
  tmp=$(fm_test_tmproot fm-lint-hasher)
  curlbin=$(fm_fakebin "$tmp")
  # A curl that writes the archive locally, so the checksum step is reached with
  # no network. It honours -o because that is how the installer names its target.
  cat > "$curlbin/curl" <<'SH'
#!/usr/bin/env bash
target=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) target=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$target" ] || exit 1
printf 'not the pinned archive\n' > "$target"
SH
  chmod +x "$curlbin/curl"

  # A hasher that is present but fails.
  badhasher="$tmp/badhasher"
  mkdir -p "$badhasher"
  cat > "$badhasher/shasum" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$badhasher/shasum"
  rc=0
  out=$(PATH="$badhasher:$curlbin:$PATH" "$INSTALLER" "$tmp/dest" 2>&1) || rc=$?
  expect_code 1 "$rc" "a hasher that fails must refuse"
  assert_contains "$out" "REFUSING" "a failed hasher must read as a refusal"
  assert_contains "$out" "hasher failure" "a failed hasher must be named as the cause"
  assert_not_contains "$out" "checksum mismatch for" "a failed hasher must not be blamed on the download"
  assert_absent "$tmp/dest/shellcheck" "an unhashed download must never be installed"

  # No hasher at all. Built by removing both tools from the base PATH, because
  # the installer reads presence with command -v and a stub still reads present.
  base=$(fm_hermetic_base_path "$tmp/farm" shasum sha256sum)
  rc=0
  out=$(PATH="$curlbin:$base" "$INSTALLER" "$tmp/dest-none" 2>&1) || rc=$?
  expect_code 1 "$rc" "a machine with no hasher must refuse"
  assert_contains "$out" "no SHA-256 tool found" "the no-hasher refusal must name the missing tool"
  assert_absent "$tmp/dest-none/shellcheck" "an unhashed download must never be installed"
  pass "a broken hasher and a missing one each refuse by their own name"
}

test_installer_extraction_needs_no_xz() {
  # GNU tar shells out for both -J and -z, but gzip is an essential package
  # everywhere and xz-utils is not, so the .tar.gz assets (byte-identical
  # payloads upstream) remove a dependency a stripped machine can lack.
  assert_grep 'tar -xzf' "$INSTALLER" "the installer must extract the gzip asset"
  assert_no_grep 'tar -xJf' "$INSTALLER" "the installer must not depend on an external xz"
  # Asserted on what every platform actually resolves, so the prose above may
  # keep explaining the xz assets without the check reading them as a fetch.
  local os arch token out
  while read -r os arch token; do
    out=$(print_asset_for "$os" "$arch") || fail "installer refused a claimed platform ($os/$arch)"
    case "$(asset_field "$out" archive)" in
      *.tar.gz) : ;;
      *) fail "$os/$arch resolves a non-gzip asset, reintroducing the xz dependency" ;;
    esac
  done <<CLAIMED
$CLAIMED_PLATFORMS
CLAIMED
  pass "extraction depends on gzip only, never on xz"
}

test_installer_matrix_is_bound_to_the_pinned_version() {
  # Every checksum is version-specific. If the pin moves and the matrix does not,
  # the honest outcome is one refusal naming the cause, not six identical
  # checksum mismatches with no hint of why.
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-matrix)
  mkdir -p "$tmp/bin"
  cp "$INSTALLER" "$tmp/bin/"
  cat > "$tmp/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
printf '9.9.9\n'
SH
  chmod +x "$tmp/bin/fm-lint.sh"
  rc=0
  out=$("$tmp/bin/fm-install-shellcheck.sh" --print-asset 2>&1) || rc=$?
  expect_code 1 "$rc" "the installer must refuse when its matrix predates the pin"
  assert_contains "$out" "REFUSING" "a stale matrix must read as a refusal"
  assert_contains "$out" "$REQUIRED" "the refusal must name the version the checksums were recorded for"
  assert_contains "$out" "9.9.9" "the refusal must name the version now pinned"
  pass "a moved pin refuses with its cause instead of mismatching every checksum"
}

test_ensure_mode_is_not_reportable_as_a_lint_pass() {
  # A resolve that linted nothing must not be shaped like a lint run: exit status
  # is what automation reads, and a path on stdout is not a distinction.
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): resolve-only output check"
    return
  fi
  local out rc
  rc=0
  out=$(FM_LINT_NO_PROVISION=1 "$LINT" --ensure-shellcheck 2>&1 >/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || fail "--ensure-shellcheck must exit zero on a successful resolve"$'\n'"$out"
  assert_contains "$out" "RESOLVE ONLY" "the resolve-only mode must announce itself as such"
  assert_contains "$out" "NO FILES WERE LINTED" "the resolve-only mode must state that it linted nothing"
  pass "--ensure-shellcheck cannot be mistaken for a lint pass"
}

test_resolution_survives_ambient_shellcheck_opts() {
  # ShellCheck parses SHELLCHECK_OPTS even for --version and exits non-zero on an
  # option it rejects, so a stale ambient value must not make the pinned build
  # look unresolvable and trigger a pointless download and a refusal.
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options resolution check"
    return
  fi
  local out rc
  rc=0
  out=$(SHELLCHECK_OPTS='--not-a-real-flag' FM_LINT_NO_PROVISION=1 "$LINT" --ensure-shellcheck 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "ambient SHELLCHECK_OPTS made the pinned build look unresolvable"$'\n'"$out"
  pass "version resolution ignores ambient ShellCheck options"
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
test_bootstrap_remediation_is_real_and_agrees_with_the_refusal
test_installer_bounds_its_download
test_installer_selects_an_asset_per_claimed_platform
test_installer_never_falls_through_to_another_architecture
test_installer_refuses_unclaimed_architectures_by_name
test_installer_separates_provenance_from_runtime_evidence
test_installer_hashes_without_gnu_coreutils
test_installer_separates_a_broken_hasher_from_a_bad_download
test_installer_extraction_needs_no_xz
test_installer_matrix_is_bound_to_the_pinned_version
test_ensure_mode_is_not_reportable_as_a_lint_pass
test_resolution_survives_ambient_shellcheck_opts
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
