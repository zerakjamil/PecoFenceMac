#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build="${PECOFENCE_BUILD_DIR:-$HOME/Library/Caches/PecoFence/build}"
mkdir -p "$build"
swiftc -swift-version 5 -D PECOFENCE_TESTS \
  -framework AppKit -framework SwiftUI -framework Carbon -framework Quartz \
  macos/Sources/Models.swift macos/Sources/DeveloperTools.swift macos/Sources/DesktopVisibility.swift macos/Sources/Views.swift macos/Sources/App.swift \
  macos/Tests/DeveloperToolsTests.swift -o "$build/developer-tests"
"$build/developer-tests"
