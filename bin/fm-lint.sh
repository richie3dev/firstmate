#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs ShellCheck over firstmate's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# The lint command, the file set, the config, AND the pinned ShellCheck version
# live here and ONLY here, so the gates cannot drift apart: both invoke this
# script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/fm-lint.sh`.
#   - Pre-push: .no-mistakes.yaml `commands.lint` runs `bin/fm-lint.sh`, so the
#               no-mistakes gate runs the SAME shellcheck as CI. Without a
#               configured commands.lint, that gate step never ran this
#               deterministic shellcheck, so info-level findings were not
#               surfaced locally before CI rejected them.
#
# Version parity: CI's ShellCheck used to float with the runner image, and
# ShellCheck retired SC2015 in 0.11.0, so an older CI ShellCheck rejected an
# SC2015 that a newer local one no longer emits. This script pins one exact
# version (REQUIRED_SHELLCHECK) and lints with that version and no other, so CI
# and local run the identical rule set. This is not a CI relaxation: it adopts
# one upstream release consistently; the only difference from the old floating
# CI is dropping the upstream-retired, false-positive-prone SC2015.
# No severity downgrade and no blanket exclude of checks - every still-supported
# finding at default severity is enforced.
# The local == CI parity contract is asserted by tests/fm-lint.test.sh.
#
# Resolving the pinned build: PATH first (this is CI's case - the workflow
# installs the pin and prepends it), then a private version-keyed cache under
# FM_SHELLCHECK_CACHE (default ${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/shellcheck),
# and otherwise provision the cache via bin/fm-install-shellcheck.sh. The cache
# is deliberately NOT on anyone's PATH and is keyed by version, so provisioning
# never rewrites a shared system shellcheck and never overwrites a binary another
# concurrent run may be executing; the machine's own `shellcheck` is left exactly
# as it was. Set FM_LINT_NO_PROVISION=1 to forbid provisioning (offline or
# hermetic callers); the script then refuses rather than linting at any other
# version. There is deliberately no degraded mode: a run at a non-pinned version
# is never performed, so a passing exit status always means the pinned rule set
# passed.
#
# Usage:
#   fm-lint.sh                    lint the canonical file set (what both gates run)
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   fm-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#   fm-lint.sh --ensure-shellcheck resolve (provisioning if needed) the pinned
#                                  ShellCheck, print its path, and exit; used at
#                                  session start so the gate is ready before push
#                                  time rather than failing at it. It lints
#                                  nothing and says so, so a successful resolve
#                                  can never be read as a lint pass.
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or the gate)
# fails exactly when ShellCheck reports a finding; an unresolvable pinned
# ShellCheck fails before linting with a distinct message.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`; the test suite reads it the same way.
REQUIRED_SHELLCHECK=0.11.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Expose the pinned version without needing ShellCheck installed, so CI can read
# it to install the exact same build before any lint runs.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

# Neutralized before ANY ShellCheck invocation, version probes included:
# ShellCheck parses SHELLCHECK_OPTS even for --version and exits non-zero on an
# option it rejects, so an ambient value would make the pinned build look
# unresolvable and send this script down the refusal path.
unset SHELLCHECK_OPTS

cache_root() {
  printf '%s\n' "${FM_SHELLCHECK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/shellcheck}"
}

probe_version() {
  "$1" --version 2>/dev/null | awk '/^version:/ {print $2; exit}'
}

# Print the path of a ShellCheck that IS the pinned version, or fail. Never
# returns a path to any other version.
resolve_pinned() {
  local candidate cached
  if candidate=$(command -v shellcheck 2>/dev/null) \
    && [ "$(probe_version "$candidate")" = "$REQUIRED_SHELLCHECK" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  cached="$(cache_root)/$REQUIRED_SHELLCHECK/shellcheck"
  if [ -x "$cached" ] && [ "$(probe_version "$cached")" = "$REQUIRED_SHELLCHECK" ]; then
    printf '%s\n' "$cached"
    return 0
  fi
  return 1
}

# Populate the version-keyed cache. Staging plus an atomic rename means a
# concurrent lint run keeps executing the inode it already opened, so this is
# safe to run while other work is mid-pipeline on the same machine.
provision_pinned() {
  local dir staging
  dir="$(cache_root)/$REQUIRED_SHELLCHECK"
  staging="$(cache_root)/.staging.$$"
  mkdir -p "$dir" || return 1
  if ! "$ROOT/bin/fm-install-shellcheck.sh" "$staging" >&2; then
    rm -rf "$staging"
    return 1
  fi
  mv -f "$staging/shellcheck" "$dir/shellcheck" || { rm -rf "$staging"; return 1; }
  rm -rf "$staging"
  [ "$(probe_version "$dir/shellcheck")" = "$REQUIRED_SHELLCHECK" ]
}

# Report what the machine currently resolves, so a refusal names the version that
# actually got in the way instead of just "not the pin".
found_version() {
  local candidate
  candidate=$(command -v shellcheck 2>/dev/null) || { printf 'none\n'; return 0; }
  printf '%s\n' "$(probe_version "$candidate")"
}

refuse() {
  local found=$1
  if [ "$found" = none ]; then
    printf 'fm-lint.sh: REFUSING TO LINT - ShellCheck %s is required and could not be resolved or installed.\n' \
      "$REQUIRED_SHELLCHECK" >&2
  else
    printf 'fm-lint.sh: REFUSING TO LINT - ShellCheck %s is required for CI parity, found %s, and the pinned build could not be installed.\n' \
      "$REQUIRED_SHELLCHECK" "$found" >&2
  fi
  printf 'fm-lint.sh: NOTHING WAS LINTED. This is not a pass, and linting by hand at another version does not substitute for it: it reports a different rule set than CI enforces.\n' >&2
  printf 'fm-lint.sh: install the pinned build with: bin/fm-lint.sh --ensure-shellcheck (provisions %s/%s via bin/fm-install-shellcheck.sh; that cache is deliberately never on PATH)\n' \
    "$(cache_root)" "$REQUIRED_SHELLCHECK" >&2
}

SHELLCHECK_BIN=$(resolve_pinned) || {
  found=$(found_version)
  if [ "${FM_LINT_NO_PROVISION:-0}" = 1 ] || ! provision_pinned; then
    refuse "$found"
    [ "$found" = none ] && exit 127
    exit 1
  fi
  SHELLCHECK_BIN=$(resolve_pinned) || { refuse "$found"; exit 1; }
}

# Resolve-only mode. Its success must never read like a lint pass in a scrollback
# or a captured log, so it says outright that it linted nothing rather than
# leaving a path on stdout as the only difference from a real run.
if [ "${1:-}" = "--ensure-shellcheck" ]; then
  printf 'fm-lint.sh: RESOLVE ONLY - ShellCheck %s (pinned %s) is ready at %s.\n' \
    "$(probe_version "$SHELLCHECK_BIN")" "$REQUIRED_SHELLCHECK" "$SHELLCHECK_BIN" >&2
  printf 'fm-lint.sh: NO FILES WERE LINTED by this mode - it only readies the gate. Run bin/fm-lint.sh with no arguments to lint.\n' >&2
  printf '%s\n' "$SHELLCHECK_BIN"
  exit 0
fi

# Log the resolved version to stderr so both CI and local runs record it.
printf 'fm-lint.sh: ShellCheck %s (pinned %s) at %s\n' \
  "$(probe_version "$SHELLCHECK_BIN")" "$REQUIRED_SHELLCHECK" "$SHELLCHECK_BIN" >&2

if [ "$#" -gt 0 ]; then
  exec "$SHELLCHECK_BIN" --norc "$@"
fi

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs.
exec "$SHELLCHECK_BIN" --norc bin/*.sh bin/backends/*.sh tests/*.sh
