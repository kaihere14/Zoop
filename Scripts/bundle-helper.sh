#!/bin/bash
# Builds build/ZoopHelper.app and build/zoop-bridge in release mode and signs the helper.
#
# Signing matters: macOS ties privacy permissions (Screen Recording, Accessibility) to the
# app's code signature. An ad-hoc signature changes on every build, so every rebuild would
# lose the permissions granted in the agent session. A certificate signature stays the same.
# Set ZOOP_SIGN_IDENTITY to choose the certificate (default: "SessionBridge Dev").
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools lack the Swift Testing macros; prefer the full Xcode toolchain.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --product ZoopHelper
swift build -c release --product zoop-bridge
BIN="$(swift build -c release --show-bin-path)"

APP=build/ZoopHelper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/ZoopHelper" "$APP/Contents/MacOS/ZoopHelper"
cp Resources/InfoPlists/ZoopHelper-Info.plist "$APP/Contents/Info.plist"
cp "$BIN/zoop-bridge" build/zoop-bridge

IDENTITY_NAME="${ZOOP_SIGN_IDENTITY:-SessionBridge Dev}"
IDENTITY="$(security find-identity -p codesigning | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }')"
if [[ -z "$IDENTITY" ]]; then
    echo "warning: signing identity '$IDENTITY_NAME' not found; using ad-hoc signing." >&2
    echo "         Permissions granted to the helper will reset on every rebuild." >&2
fi
codesign --force --sign "${IDENTITY:--}" --identifier com.zoop.helper "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

echo "built $APP and build/zoop-bridge"
