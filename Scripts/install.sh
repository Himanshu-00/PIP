#!/bin/bash
#
# Build → /Applications → clean permissions → launch.
#
# Why this exists: an app launched by Xcode is a debugged child process living
# in DerivedData, and both of those things break TCC. macOS can attribute the
# app's permission prompts to Xcode instead of to the app, and the copy in
# DerivedData is deleted and rebuilt on every compile — so a grant, even a
# correct one, ends up pointing at a file that no longer exists.
#
# Running this once after each build gives macOS a stable app at a stable path,
# which is the only arrangement it will remember.
#
#   ./Scripts/install.sh          build, install, relaunch
#   ./Scripts/install.sh --reset  also wipe every permission and start clean
#
set -euo pipefail

BUNDLE_ID="com.himanshu.DynamicNotch"
APP_NAME="Pip.app"
DEST="/Applications/${APP_NAME}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# System Settings caches the privacy lists hard and will not refresh while it's
# open. Every "I toggled it and nothing happened" starts here.
if pgrep -xq "System Settings"; then
  say "Quitting System Settings (it caches the privacy lists)"
  osascript -e 'quit app "System Settings"' || true
  sleep 1
fi

say "Stopping every running copy"
killall Pip DynamicNotch 2>/dev/null || true
sleep 0.5

say "Building (Release)"
# Release, not Debug: the on-device model's engine (MLX) is a package, and
# packages built for Debug are compiled without optimisation. Fine for
# stepping through code; noticeably slower for running a language model.
xcodebuild -project "${ROOT}/Pip.xcodeproj" \
           -scheme Pip \
           -configuration Release \
           -derivedDataPath "${ROOT}/.build" \
           build | tail -5

BUILT="${ROOT}/.build/Build/Products/Release/${APP_NAME}"
if [[ ! -d "${BUILT}" ]]; then
  echo "Build succeeded but ${BUILT} isn't there. Check the scheme name." >&2
  exit 1
fi

say "Installing to /Applications"
# Replace in place rather than deleting first: keeping the same path is half of
# what makes the permission stick.
rm -rf "${DEST}"
cp -R "${BUILT}" "${DEST}"

if [[ "${1:-}" == "--reset" ]]; then
  say "Clearing every permission for ${BUNDLE_ID}"
  # No password needed — you can always reset your own app's entries.
  tccutil reset All "${BUNDLE_ID}" 2>/dev/null || true
  echo "Cleared. macOS will ask again on first use."
fi

say "Signature"
codesign -dv --verbose=2 "${DEST}" 2>&1 | grep -E 'Identifier|Authority|Signature' || true

say "Launching from /Applications"
open "${DEST}"

cat <<'NOTE'

Done.

If a permission prompt appears, accept it — the grant now belongs to the copy
in /Applications, which doesn't move or get rebuilt underneath it.

If macOS says "quit and reopen to take effect", believe it: the permission is
read once when the process starts, so the running copy keeps the old answer
until it's restarted.

To watch what macOS is actually deciding, in another terminal:

  log stream --style compact \
    --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "ScreenCapture"'

NOTE
