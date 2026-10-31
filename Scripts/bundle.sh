#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Zoop’s AppKit UI must be built on the project’s macOS 27+ / Xcode 27 toolchain." >&2
    exit 1
fi

# Use full Xcode when Command Line Tools are selected, as required by the shared package.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$project_dir" --configuration release --product Zoop
binary_dir="$(swift build --package-path "$project_dir" --configuration release --show-bin-path)"
app_dir="$project_dir/build/Zoop.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 755 "$binary_dir/Zoop" "$app_dir/Contents/MacOS/Zoop"
install -m 644 "$project_dir/Resources/InfoPlists/Zoop-Info.plist" "$app_dir/Contents/Info.plist"
install -m 644 "$project_dir/Sources/ZoopApp/Resources/completion.mp3" "$app_dir/Contents/Resources/completion.mp3"
/usr/bin/codesign --force --sign - "$app_dir"
printf '\nBuilt: %s\nLaunch: open "%s"\n' "$app_dir" "$app_dir"
