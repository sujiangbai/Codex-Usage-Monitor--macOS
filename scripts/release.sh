#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Package only committed files; never include an installed app or local data.
git diff --quiet
git diff --cached --quiet
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
revision=$(git rev-parse HEAD)
release_dir="$PWD/build/releases/v${version}"
if [[ -e "$release_dir" ]]; then
  print -u2 "Release output already exists: $release_dir"
  exit 1
fi
release_work=$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-release.XXXXXX")
trap 'rm -rf "$release_work"' EXIT
mkdir -p "$release_work/source" "$release_work/output"
git archive HEAD | tar -x -C "$release_work/source"
zsh "$release_work/source/test.sh"
zsh "$release_work/source/build.sh"

app="$release_work/source/build/Codex Usage Monitor.app"
codesign --verify --strict "$app"
[[ "$(lipo -archs "$app/Contents/MacOS/CodexQuota")" == "arm64" ]]
package_name="Codex-Usage-Monitor-v${version}-macOS-arm64"
package="$release_work/$package_name"
mkdir -p "$package"
cp "$release_work/source/LICENSE" "$release_work/source/NOTICE" "$package/"
cp "$release_work/source/PRIVACY.md" "$release_work/source/SECURITY.md" "$package/"
ditto --norsrc --noextattr --noqtn "$app" "$package/Codex Usage Monitor.app"
codesign --verify --strict "$package/Codex Usage Monitor.app"
cat > "$package/INSTALL.txt" <<EOF
Codex Usage Monitor v${version}
Source commit: ${revision}
Repository: https://github.com/sujiangbai/Codex-Usage-Monitor--macOS

Requirements: Apple Silicon Mac (arm64), macOS 13 or later.
Install the official Codex app and sign in with your ChatGPT account first.

Quit any previous version of Codex Usage Monitor before updating.
Move Codex Usage Monitor.app to ~/Applications (recommended) or /Applications,
then open it. The quota indicator appears in the macOS menu bar.
Existing preferences are retained. Automatic login startup is optional.
Before the first query, review the privacy notice and choose Start monitoring.
Stop monitoring clears in-memory quota data and stops queries until you opt in
again. It does not change your separate login startup preference.

This app uses ad-hoc signing and is NOT Apple-notarized. macOS may block the
downloaded application because its developer cannot be verified. Building from
source on your own Mac is an alternative; see the repository README.
No global security setting changes are required by the app.

The app does not bundle credentials, usage records or the official Codex binary.
It asks the installed official Codex process for quota data using existing login.
This is an independent project, not an official OpenAI product.
Licensed under Apache-2.0; see LICENSE and NOTICE. Quota data is informational;
the official service is authoritative. No guarantee of real-time accuracy,
continued compatibility or maintenance. See PRIVACY.md and SECURITY.md.
EOF
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$package" "$release_work/output/$package_name.zip"
(
  cd "$release_work/output"
  shasum -a 256 "$package_name.zip" > SHA256SUMS.txt
)
mkdir -p "${release_dir:h}"
mv "$release_work/output" "$release_dir"
print -r -- "$release_dir"
