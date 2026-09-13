#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/module-cache 'build/Codex Usage Monitor.app/Contents/MacOS' 'build/Codex Usage Monitor.app/Contents/Resources'
xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/build/module-cache" \
  -file-prefix-map "$PWD=." -debug-prefix-map "$PWD=." \
  -target arm64-apple-macosx13.0 Sources/Quota.swift Sources/CodexClient.swift Sources/PanelPlacement.swift Sources/GlassUI.swift Sources/App.swift \
  -o 'build/Codex Usage Monitor.app/Contents/MacOS/CodexQuota' \
  -framework AppKit -framework SwiftUI -framework ServiceManagement
cp Info.plist 'build/Codex Usage Monitor.app/Contents/Info.plist'
cp Resources/AppIcon.icns 'build/Codex Usage Monitor.app/Contents/Resources/AppIcon.icns'
cp LICENSE NOTICE 'build/Codex Usage Monitor.app/Contents/Resources/'
codesign --force --sign - --identifier local.codexquota.menubar 'build/Codex Usage Monitor.app'
printf '%s\n' "$PWD/build/Codex Usage Monitor.app"
