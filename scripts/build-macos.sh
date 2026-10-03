#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bundle="${PECOFENCE_BUILD_DIR:-$HOME/Library/Caches/PecoFence/build}/PecoFence.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cargo build --locked --release -p pecofence-mac-cli
cp target/release/pecofence-mac-cli "$bundle/Contents/MacOS/"
cp macos/Info.plist "$bundle/Contents/Info.plist"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework SwiftUI -framework Carbon -framework Quartz \
  macos/Sources/Models.swift macos/Sources/DeveloperTools.swift macos/Sources/DesktopVisibility.swift macos/Sources/Views.swift macos/Sources/App.swift \
  -o "$bundle/Contents/MacOS/PecoFence"
cp -X LICENSE NOTICE "$bundle/Contents/Resources/"
xattr -cr "$bundle"
codesign --force --deep --sign - "$bundle"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$bundle" "dist/PecoFence-macOS-$(uname -m).zip"
printf 'Built %s\n' "$bundle"
