#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build for
# whatever platform this machine actually is.
#
# Why this is arch-aware: bin/fm-lint.sh refuses to lint at any version but the
# pin, and reaches this installer to provision it. A hardcoded linux.x86_64
# asset therefore did not degrade on an arm64 Linux or a macOS contributor's
# machine - it took the whole lint gate offline there, which is the CI-only-lint
# state the pin exists to prevent. firstmate has external contributors on
# hardware this project does not own, so every platform upstream publishes an
# asset for is claimed here, and every platform it does not is refused BY NAME.
#
# THE CHECKSUM RULE. An unverified checksum is worse than no support: it turns a
# loud refusal into silent trust of an unverified binary. So every row of the
# matrix below carries a sha256 obtained by a method that can be described, and
# the row's last field states which of two DIFFERENT claims that evidence backs:
#   runtime-verified - the pinned build for this platform is executed here (CI
#                      and the project's own machines run it on every push).
#   checksum-only    - the bytes are provably the ones upstream published, by
#                      two independent methods: GitHub's per-asset release
#                      digest, and downloading the asset and hashing it. That is
#                      PROVENANCE. It is NOT evidence that the binary RUNS on
#                      that architecture. Only executing it on real hardware of
#                      that architecture shows that, and this project owns no
#                      arm64, armv6hf, riscv64, or macOS hardware. The install
#                      below ends by running `shellcheck --version`, so the
#                      first person on such a machine gets that answer loudly
#                      instead of a silently broken gate.
# Do not add a row whose checksum was not obtained that way, and do not promote
# a row to runtime-verified without having run that build on that hardware.
#
# Archive format: the .tar.gz assets, not the .tar.xz ones, although upstream
# publishes both with byte-identical payloads. GNU tar shells out to an external
# helper for both -J and -z and fails outright when it is missing ("tar (child):
# xz: Cannot exec"), but gzip is an essential package everywhere while xz-utils
# routinely is not, so .tar.gz trades a dependency a minimal container or a
# stripped machine can fail to satisfy for one it effectively cannot, at the
# cost of a few hundred KB more download. When even gzip is missing, the
# extraction below refuses by name rather than leaking tar's own error.
#
# Checksumming: `shasum -a 256` first, `sha256sum` second. sha256sum is GNU
# coreutils and is NOT present on a stock macOS, so selecting the right asset
# while still hashing it with sha256sum would leave macOS broken one line later.
# This is the same ordering the rest of firstmate's scripts use.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
#   fm-install-shellcheck.sh --print-asset   resolve this machine's asset, URL,
#                                            checksum, and evidence level, then
#                                            exit. Downloads nothing, so the
#                                            selection and refusal logic can be
#                                            exercised offline.
#
# FM_SHELLCHECK_UNAME_S / FM_SHELLCHECK_UNAME_M override platform detection.
# They exist so the test suite can exercise every claimed platform and every
# refusal from one machine; they select an asset and never relax the checksum.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The ShellCheck release every checksum below was recorded from. bin/fm-lint.sh
# remains the single owner of the pin itself; this is only the assertion that
# the matrix was re-recorded when that pin moved. Without it, a version bump
# becomes an identical checksum mismatch on every platform with no hint of the
# real cause.
MATRIX_VERSION=0.11.0

# THE ASSET MATRIX - one row per claimed platform, and the single owner of what
# this installer supports. Both the selector and the refusal message read it, so
# the two cannot drift.
#
# Fields: uname -s | uname -m alternates | upstream platform token | sha256 of
# the asset named "shellcheck-v<MATRIX_VERSION>.<token>.tar.gz" | evidence level.
# Carrying the checksum in the row means an asset cannot be added without one.
#
# Deliberately not claimed, because upstream publishes no such asset at this
# version: 32-bit x86 Linux, FreeBSD, and Windows (the .zip holds a Windows
# .exe, not something this extract-and-install path can use).
#
# linux.armv6hf is upstream's only 32-bit ARM build, and it is hard-float.
# uname -m reports armv6l/armv7l/armv8l without reporting the float ABI, so that
# mapping rests on an assumption uname cannot confirm; a soft-float machine gets
# the named failure from the final --version run rather than a quiet wrong gate.
supported_rows() {
  cat <<'ROWS'
Linux|x86_64 amd64|linux.x86_64|b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6|runtime-verified
Linux|aarch64 arm64|linux.aarch64|68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc|checksum-only
Linux|armv6l armv7l armv8l|linux.armv6hf|89f29e76e881122416eb95947f812b1496ff9a46d1e1676abe1e3f3f903b0f46|checksum-only
Linux|riscv64|linux.riscv64|a70e86454e9ae1a328aeafe62629d04ffea93b99138bfe1203083e2621b5ca4f|checksum-only
Darwin|x86_64|darwin.x86_64|c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51|checksum-only
Darwin|arm64 aarch64|darwin.aarch64|339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f|checksum-only
ROWS
}

# Print "<token> <sha256> <evidence>" for a uname pair, or fail. Never guesses:
# an unlisted pair fails, and never falls through to the nearest-looking row.
select_platform() {
  local want_os=$1 want_arch=$2 row_os row_arches token sha evidence arch
  while IFS='|' read -r row_os row_arches token sha evidence; do
    [ "$row_os" = "$want_os" ] || continue
    for arch in $row_arches; do
      if [ "$arch" = "$want_arch" ]; then
        printf '%s %s %s\n' "$token" "$sha" "$evidence"
        return 0
      fi
    done
  done <<ROWS
$(supported_rows)
ROWS
  return 1
}

# The claimed platforms, rendered from the matrix so the refusal below names
# exactly what the selector accepts.
claimed_platforms() {
  local row_os row_arches rest out=
  while IFS='|' read -r row_os row_arches rest; do
    out="$out${out:+; }$row_os $row_arches (${rest##*|})"
  done <<ROWS
$(supported_rows)
ROWS
  printf '%s\n' "$out"
}

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
if [ "$VERSION" != "$MATRIX_VERSION" ]; then
  printf 'fm-install-shellcheck.sh: REFUSING - the checksum matrix in this script was recorded for ShellCheck %s, but bin/fm-lint.sh now pins %s.\n' \
    "$MATRIX_VERSION" "$VERSION" >&2
  printf 'fm-install-shellcheck.sh: re-record every row from the sha256 GitHub publishes for each v%s asset and move MATRIX_VERSION with them. Installing at an unrecorded version could only produce a checksum mismatch on every platform.\n' \
    "$VERSION" >&2
  exit 1
fi

OS=${FM_SHELLCHECK_UNAME_S:-$(uname -s)}
ARCH=${FM_SHELLCHECK_UNAME_M:-$(uname -m)}

if ! PLATFORM_RECORD=$(select_platform "$OS" "$ARCH"); then
  # Refuse for THIS machine by name. Someone on an unsupported box must learn in
  # one line why the lint gate will not come up, not go debugging the gate.
  printf 'fm-install-shellcheck.sh: REFUSING - no verified ShellCheck %s build is claimed for this machine: uname -s=%s uname -m=%s.\n' \
    "$VERSION" "$OS" "$ARCH" >&2
  printf 'fm-install-shellcheck.sh: claimed platforms are %s.\n' "$(claimed_platforms)" >&2
  printf 'fm-install-shellcheck.sh: upstream lists every published asset at https://github.com/koalaman/shellcheck/releases/tag/v%s - if one fits this machine, add its row to the asset matrix in this script with the sha256 GitHub publishes for that asset. If none fits, install ShellCheck %s for this platform by other means and put it on PATH, which bin/fm-lint.sh resolves before reaching this installer.\n' \
    "$VERSION" "$VERSION" >&2
  exit 1
fi
read -r PLATFORM SHA256 EVIDENCE <<<"$PLATFORM_RECORD"

ARCHIVE="shellcheck-v${VERSION}.${PLATFORM}.tar.gz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"

if [ "${1:-}" = "--print-asset" ]; then
  printf 'platform: %s\narchive: %s\nsha256: %s\nevidence: %s\nurl: %s\n' \
    "$PLATFORM" "$ARCHIVE" "$SHA256" "$EVIDENCE" "$URL"
  exit 0
fi

DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Bounded: bin/fm-lint.sh reaches this installer automatically from the pre-push
# lint gate, so a stalled connection must fail into that gate's refusal path
# instead of hanging the gate with no output.
curl -fsSL --connect-timeout 10 --max-time 120 "$URL" -o "$TMP/$ARCHIVE"

if ! ACTUAL_SHA256=$(file_sha256 "$TMP/$ARCHIVE"); then
  printf 'fm-install-shellcheck.sh: REFUSING - no SHA-256 tool found. Install shasum (preinstalled on macOS) or sha256sum (GNU coreutils); the download is never trusted unhashed.\n' >&2
  exit 1
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ARCHIVE" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}

if ! tar -xzf "$TMP/$ARCHIVE" -C "$TMP"; then
  printf 'fm-install-shellcheck.sh: REFUSING - could not extract %s; tar with gzip decompression is required.\n' "$ARCHIVE" >&2
  exit 1
fi
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"

# The one check no checksum can stand in for: that this build RUNS here. On a
# checksum-only platform this is its first execution on that hardware, so a
# failure is reported as exactly that rather than as a broken download.
if ! "$DESTINATION/shellcheck" --version; then
  printf 'fm-install-shellcheck.sh: REFUSING - the %s build of ShellCheck %s downloaded and matched its published checksum, but will not execute here: uname -s=%s uname -m=%s.\n' \
    "$PLATFORM" "$VERSION" "$OS" "$ARCH" >&2
  if [ "$EVIDENCE" = checksum-only ]; then
    printf 'fm-install-shellcheck.sh: that asset is claimed on published-checksum evidence alone and has never been run on this architecture, so suspect this mapping first. Please report it with the two uname values above.\n' >&2
  fi
  rm -f "$DESTINATION/shellcheck"
  exit 1
fi
