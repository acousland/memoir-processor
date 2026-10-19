#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
xcodegen generate
xcodebuild -project MemoirProcessor.xcodeproj -scheme MemoirProcessorApp -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build
app="$root/dist/Memoir Processor.app"
mkdir -p dist
rm -rf "$app"
ditto 'DerivedData/Build/Products/Release/Memoir Processor.app' "$app"
# The agent belongs in Contents/MacOS; remove copies left by older project generation.
rm -f "$app/Contents/Resources/MemoirProcessorAgent"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(cat Assets/version)" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(cat Assets/build-number)" "$app/Contents/Info.plist"
scripts/sign-app.sh "$app"
echo "$app"
