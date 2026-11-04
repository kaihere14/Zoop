#!/bin/bash
# Fetch the native macOS CLI and its required companion. No Node runtime is bundled.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "agent-desktop bundling requires macOS" >&2; exit 1; }

VERSION=1.1.0
case "$(uname -m)" in
    arm64)
        TARGET=aarch64-apple-darwin
        EXPECTED=3048e00aa0741bf25ffe0326f78c966408be4490ce13513f3f94ecf2a0b5270d
        ;;
    x86_64)
        TARGET=x86_64-apple-darwin
        EXPECTED=b6352ac66aa49e0280c6f690de791dc03c827623a838950856b20ddbebcdc382
        ;;
    *) echo "Unsupported Mac architecture" >&2; exit 1 ;;
esac
DEST="build/agent-desktop/$VERSION/$TARGET"
if [[ -x "$DEST/agent-desktop" && -x "$DEST/agent-desktop-macos-helper" && -f "$DEST/LICENSE" ]]; then
    printf '%s\n' "$PWD/$DEST"
    exit 0
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ARCHIVE="agent-desktop-v$VERSION-$TARGET.tar.gz"
BASE="https://github.com/vercel-labs/agent-desktop/releases/download/v$VERSION"
curl -fLsS --retry 3 "$BASE/$ARCHIVE" -o "$STAGING/$ARCHIVE"
# Digests pinned from the v1.1.0 GitHub release assets/checksums.txt.
ACTUAL="$(shasum -a 256 "$STAGING/$ARCHIVE" | awk '{print $1}')"
[[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ && "$EXPECTED" == "$ACTUAL" ]] || { echo "agent-desktop checksum mismatch" >&2; exit 1; }
LISTING="$(tar -tzf "$STAGING/$ARCHIVE" | LC_ALL=C sort)"
[[ "$LISTING" == $'agent-desktop\nagent-desktop-macos-helper' ]] || { echo "Unexpected agent-desktop archive contents" >&2; exit 1; }
tar -xzf "$STAGING/$ARCHIVE" -C "$STAGING"
curl -fLsS --retry 3 "https://raw.githubusercontent.com/vercel-labs/agent-desktop/v$VERSION/LICENSE" -o "$STAGING/LICENSE"
mkdir -p "$DEST"
cp "$STAGING/agent-desktop" "$STAGING/agent-desktop-macos-helper" "$STAGING/LICENSE" "$DEST/"
chmod 755 "$DEST/agent-desktop" "$DEST/agent-desktop-macos-helper"
printf '%s\n' "$PWD/$DEST"
