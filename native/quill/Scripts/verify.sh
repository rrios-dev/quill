#!/bin/bash
#
# Quill's merge gate (ARCHITECTURE §10, README D-18).
#
# The repository's Forgejo runs only .forgejo/workflows on a runner that is not a Mac,
# so nothing hosted checks this package. This script is the gate instead: run it at
# the end of every phase and before every merge, and quote its output in the PR.
# Later tasks append their checks here; none is ever removed or weakened to pass.
#
#   Scripts/verify.sh
#
set -euo pipefail

QUILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$(cd "$QUILL/.." && pwd)"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/quill-verify.XXXXXX")"
trap 'rm -rf "$LOGS"' EXIT

step() { echo "▸ $*"; }
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

# Zero warnings after a forced rebuild, and green tests (PLAN §1 rule 2). Live tests
# stay off: they need Apple Intelligence or a provider, and the gate must not.
forced_build_and_test() {
  local dir="$1" name="$2"
  shift 2
  step "$name: forced rebuild with zero warnings"
  ( cd "$dir" && find . -name '*.swift' -not -path './.build/*' "$@" -exec touch {} + )
  if ! ( cd "$dir" && swift build --build-tests ) >"$LOGS/$name-build.log" 2>&1; then
    tail -40 "$LOGS/$name-build.log" >&2
    fail "$name: build failed"
  fi
  local warnings
  warnings="$(grep -c 'warning:' "$LOGS/$name-build.log" || true)"
  if [ "$warnings" != 0 ]; then
    grep 'warning:' "$LOGS/$name-build.log" | sort -u >&2
    fail "$name: $warnings warning(s)"
  fi
  pass "no warnings"

  step "$name: swift test"
  if ! ( cd "$dir" && env -u MODELKIT_LIVE_APPLE swift test ) >"$LOGS/$name-test.log" 2>&1; then
    grep -E '✘|error:' "$LOGS/$name-test.log" | head -40 >&2
    fail "$name: tests failed"
  fi
  # One summary line per test binary (an executable's test target runs in its own),
  # so every one is printed, not just the last.
  grep -E 'Test run with .* passed' "$LOGS/$name-test.log" | sed 's/^[^T]*/  ✓ /'
}

forced_build_and_test "$QUILL" quill
# Ámbar's package: Quill reuses its libraries, and Quill's tasks may add to AppCore.
forced_build_and_test "$NATIVE" native -not -path './quill/*'

# The bundle, signed, with the Hardened Runtime — for both configurations. The release
# build is also held to zero warnings: it compiles without DEBUG, so code behind
# `#if DEBUG` cannot hide what it breaks.
check_bundle() {
  local configuration="$1" app info
  step "app ($configuration): assemble and sign"
  if ! app="$("$QUILL/Scripts/make-app.sh" "$configuration" 2>"$LOGS/make-$configuration.log")"; then
    tail -40 "$LOGS/make-$configuration.log" >&2
    fail "make-app.sh $configuration failed"
  fi
  local warnings
  warnings="$(grep -c 'warning:' "$LOGS/make-$configuration.log" || true)"
  [ "$warnings" = 0 ] || { grep 'warning:' "$LOGS/make-$configuration.log" | sort -u >&2; fail "$configuration build: $warnings warning(s)"; }
  codesign --verify --strict --verbose=2 "$app" >"$LOGS/verify-$configuration.log" 2>&1 \
    || { cat "$LOGS/verify-$configuration.log" >&2; fail "codesign --verify --strict"; }
  # Captured and retried, never piped into `grep -q` (SIGPIPE under pipefail gives
  # false negatives; a read right after signing can return the cached old signature).
  info=""
  for _ in 1 2 3 4 5; do
    info="$(codesign -d --verbose=4 "$app" 2>&1 || true)"
    case "$info" in *runtime*) break ;; esac
    sleep 0.4
  done
  case "$info" in *runtime*) ;; *) fail "no Hardened Runtime on $app" ;; esac
  case "$info" in *"Signature=adhoc"*) fail "ad-hoc signature on $app" ;; esac
  # The readiness labels travel in the bundle (PLAN P4-T1).
  test -f "$app/Contents/Resources/readiness.json" || fail "no readiness.json in $app"
  pass "$app: signed, strict-valid, Hardened Runtime"
}

check_bundle debug
check_bundle release

# User text reaches the log only in debug builds (ARCHITECTURE §6, PLAN P5-T5): the
# canary in QuillLog.userText's format string is in the debug binary (the positive
# control — the check can see it) and absent from the release binary.
step "log canary: user text only in debug builds"
case "$(strings -a "$QUILL/build/debug/Quill.app/Contents/MacOS/Quill")" in
  *QUILL-USERTEXT*) ;;
  *) fail "the canary is missing from the debug binary: the check cannot see what it looks for" ;;
esac
case "$(strings -a "$QUILL/build/release/Quill.app/Contents/MacOS/Quill")" in
  *QUILL-USERTEXT*) fail "the release binary carries user-text logging" ;;
esac
pass "QUILL-USERTEXT in the debug binary, absent from the release binary"

# Every control of Quill's own UI named for VoiceOver and at least 14 pt (PLAN P5-T3).
# Opens each surface of the debug build for a few seconds; needs a graphical session.
step "accessibility of Quill's own UI"
"$QUILL/Scripts/check-accessibility.sh" "$QUILL/build/debug/Quill.app" 2>&1 | sed 's/^/  /' \
  || fail "accessibility check"

# The resource-bundle self-check (ARCHITECTURE §8). The release app must load every
# bundle from its own Contents/Resources: with .build out of reach, a bundle resolved
# through the absolute build path of this machine fails here instead of on a user's Mac.
step "release app: every built bundle packaged, --self-check with .build renamed"
RELEASE_APP="$QUILL/build/release/Quill.app"
BUILD_DIR="$QUILL/.build"
HIDDEN_BUILD="$QUILL/.build.self-check"
[ ! -e "$HIDDEN_BUILD" ] || fail "$HIDDEN_BUILD is left from an interrupted run: move it back to .build"
for built in "$BUILD_DIR"/release/*.bundle; do
  [ -d "$built" ] || continue
  [ -d "$RELEASE_APP/Contents/Resources/$(basename "$built")" ] \
    || fail "$(basename "$built") is not in Contents/Resources"
done
restore_build() { if [ -e "$HIDDEN_BUILD" ]; then mv "$HIDDEN_BUILD" "$BUILD_DIR"; fi; }
trap 'restore_build; rm -rf "$LOGS"' EXIT
mv "$BUILD_DIR" "$HIDDEN_BUILD"
self_check_status=0
"$RELEASE_APP/Contents/MacOS/Quill" --self-check >"$LOGS/self-check.log" 2>&1 || self_check_status=$?
restore_build
trap 'rm -rf "$LOGS"' EXIT
sed 's/^/  /' "$LOGS/self-check.log"
[ "$self_check_status" = 0 ] || fail "--self-check exited with $self_check_status"
pass "the release app loads its resources from its own bundle"

# Every UI string in both languages (PLAN P5-T2), and Ámbar's own check still passes with
# the parameterised script.
step "localization"
"$QUILL/Scripts/check-localization.sh" >"$LOGS/l10n-quill.log" 2>&1 \
  || { grep -E '✗' "$LOGS/l10n-quill.log" >&2; fail "Quill's localization check"; }
"$NATIVE/Scripts/check-localization.sh" >"$LOGS/l10n-native.log" 2>&1 \
  || { grep -E '✗' "$LOGS/l10n-native.log" >&2; fail "Ámbar's localization check"; }
pass "Quill and Ámbar localization checks"

# Nothing of Quill's reaches Ámbar's public repository (ARCHITECTURE §1). A fresh export
# every time, because later tasks edit files that are exported.
step "export leak check"
EXPORT="$LOGS/export"
"$NATIVE/Scripts/export-public.sh" "$EXPORT" >"$LOGS/export.log" 2>&1 \
  || { cat "$LOGS/export.log" >&2; fail "export-public.sh failed"; }
if [ -n "$(find "$EXPORT" -mindepth 1 \( -path "$EXPORT/quill" -o -path "$EXPORT/quill/*" -o -name 'ModelKit*' \))" ]; then
  fail "the export contains Quill's paths"
fi
if grep -rqi quill "$EXPORT"; then
  grep -rli quill "$EXPORT" >&2
  fail "the export mentions quill"
fi
pass "no quill in a fresh export"

# Matrix files keep valid row states (PLAN §1). The release gate adds --release in P6-T1.
step "matrix files"
REPO="$(cd "$NATIVE/.." && pwd)"
for matrix in "$REPO/docs/initiatives/quill/SPIKES.md" "$REPO/docs/initiatives/quill/QA.md"; do
  [ -f "$matrix" ] || continue
  "$QUILL/Scripts/check-matrix.sh" "$matrix" | sed 's/^/  /' || fail "$(basename "$matrix") has invalid rows"
done

echo "✓ verify.sh: all checks passed"
