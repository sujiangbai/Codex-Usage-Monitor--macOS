#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
source_app="$PWD/build/Codex Usage Monitor.app"
target_app="$HOME/Applications/Codex Usage Monitor.app"
legacy_app="$HOME/Applications/Codex Quota.app"
if [[ ! -x "$source_app/Contents/MacOS/CodexQuota" ]]; then
  zsh build.sh
fi
if [[ -e "$target_app" ]]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target_app/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$bundle_id" != "local.codexquota.menubar" ]]; then
    print -u2 '目标位置已有其他应用，未覆盖。'
    exit 1
  fi
fi
mkdir -p "$HOME/Applications"
# Preserve the existing bundle directory when adopting the new display name;
# this allows macOS login-item bookmarks to follow the renamed application.
if [[ ! -e "$target_app" && -e "$legacy_app" ]]; then
  legacy_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$legacy_app/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$legacy_id" != "local.codexquota.menubar" ]]; then
    print -u2 '旧名称位置已有其他应用，未移动。'
    exit 1
  fi
  mv "$legacy_app" "$target_app"
fi
ditto "$source_app" "$target_app"
codesign --verify --strict "$target_app"
print -r -- "$target_app"
