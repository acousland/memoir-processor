#!/bin/bash
set -euo pipefail
app=${1:?App path is required}
identity=${MEMOIR_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)}
[[ -n $identity ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 1; }
sign=(codesign --force --options runtime --timestamp --sign "$identity")
framework="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d $framework ]]; then
  "${sign[@]}" "$framework/Versions/B/XPCServices/Installer.xpc"
  "${sign[@]}" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
  "${sign[@]}" "$framework/Versions/B/Autoupdate"
  "${sign[@]}" "$framework/Versions/B/Updater.app"
  "${sign[@]}" "$framework"
fi
if [[ -x "$app/Contents/MacOS/MemoirProcessorAgent" ]]; then
  "${sign[@]}" "$app/Contents/MacOS/MemoirProcessorAgent"
fi
"${sign[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
