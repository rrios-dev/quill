#!/bin/bash
#
# Quill's CI gate: the part of verify.sh that needs a Mac but no signing
# identity and no Apple Intelligence.
#
#   Scripts/ci.sh
#
# Called by the public repository's workflow (public/ci.yml, exported to
# github.com/rrios-dev/quill) and, as its first step, by Scripts/verify.sh —
# so the hosted CI is a strict subset of the local merge gate, never a
# different list. verify.sh adds what a hosted runner cannot do: signed
# bundles, the release self-check, accessibility on the live app.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

step() { printf '\n▸ %s\n' "$*"; }

step "toolchain"
xcodebuild -version
xcrun --show-sdk-version
swift --version

step "build"
swift build

# The output guards read names with NaturalLanguage; a fresh runner may lack
# the Spanish and English name-tagging models until something asks for them.
step "language assets"
swift Scripts/request-language-assets.swift

# Live model tests are opt-in (MODELKIT_LIVE_APPLE=1) and forced off here.
step "tests"
env -u MODELKIT_LIVE_APPLE swift test

step "localization parity"
./Scripts/check-localization.sh

echo
echo "✓ ci.sh: all checks passed"
