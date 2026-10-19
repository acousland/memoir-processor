#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
profile=${MEMOIR_NOTARY_PROFILE:-renoir-notary}
xcrun notarytool history --keychain-profile "$profile" >/dev/null
read_config() { /usr/bin/python3 -c 'import json,sys; print(json.load(open("Assets/release.json"))[sys.argv[1]])' "$1"; }
app="dist/$(read_config app)"
prefix=$(read_config prefix)
repo=$(read_config repository)
version=$(cat Assets/version)
account=$(read_config sparkle_account)
if [[ ${1:-} != --skip-build ]]; then
  if [[ -f Package.swift ]]; then scripts/build-app.sh; else scripts/package_app.sh; fi
fi
codesign --verify --deep --strict "$app"
codesign -dvv "$app" 2>&1 | grep 'Authority=Developer ID Application:' >/dev/null
submit="dist/$prefix-notarization.zip"
ditto -c -k --keepParent "$app" "$submit"
echo "Submitting $app for Apple notarization..."
xcrun notarytool submit "$submit" --keychain-profile "$profile" --wait --output-format json > dist/notarization-result.json
/usr/bin/python3 -c 'import json; assert json.load(open("dist/notarization-result.json"))["status"] == "Accepted", "Notarization rejected: inspect submission log"'
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
archive="dist/$prefix-$version.zip"
ditto -c -k --keepParent "$app" "$archive"
sparkle=$(find .build/artifacts DerivedData/SourcePackages/artifacts -path '*/Sparkle/bin/sign_update' -type f -print -quit 2>/dev/null || true)
[[ -n $sparkle ]] || { echo 'Sparkle signing tool missing' >&2; exit 1; }
"$sparkle" --account "$account" -p "$archive" > dist/update-signature.txt
"$sparkle" --account "$account" --verify "$archive" "$(cat dist/update-signature.txt)"
/usr/bin/python3 scripts/write-appcast.py "$archive" "$repo" "$version" "$(cat Assets/build-number)" "$(cat dist/update-signature.txt)"
"$sparkle" --account "$account" dist/appcast.xml
"$sparkle" --account "$account" --verify dist/appcast.xml
staging=$(mktemp -d "${TMPDIR:-/tmp}/memoir-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(read_config app)"
ln -s /Applications "$staging/Applications"
dmg="dist/$prefix-$version.dmg"
hdiutil create -volname "$prefix $version" -srcfolder "$staging" -ov -format UDZO "$dmg"
identity=${MEMOIR_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)}
codesign --force --timestamp --sign "$identity" "$dmg"
echo "Submitting $dmg for Apple notarization..."
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > dist/dmg-notarization-result.json
/usr/bin/python3 -c 'import json; assert json.load(open("dist/dmg-notarization-result.json"))["status"] == "Accepted"'
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature "$dmg"
shasum -a 256 "$archive" "$dmg" > dist/SHA256SUMS
printf 'Signed, notarized, stapled and Sparkle-verified: %s\n' "$app"
