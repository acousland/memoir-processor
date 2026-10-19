#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
version=$(cat Assets/version)
repo=$(/usr/bin/python3 -c 'import json; print(json.load(open("Assets/release.json"))["repository"])')
prefix=$(/usr/bin/python3 -c 'import json; print(json.load(open("Assets/release.json"))["prefix"])')
app="dist/$(/usr/bin/python3 -c 'import json; print(json.load(open("Assets/release.json"))["app"])')"
tag="v$version"
[[ -z $(git status --porcelain) ]] || { echo 'Commit the reviewed source before publishing.' >&2; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo 'Publish from main.' >&2; exit 1; }
git fetch origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo 'Push the reviewed main commit before publishing.' >&2; exit 1; }
[[ -f dist/appcast.xml && -f "dist/$prefix-$version.zip" && -f "dist/$prefix-$version.dmg" ]] || { echo 'Run scripts/notarize-release.sh first.' >&2; exit 1; }
/usr/bin/python3 -c 'import json; assert json.load(open("dist/notarization-result.json"))["status"]=="Accepted"; assert json.load(open("dist/dmg-notarization-result.json"))["status"]=="Accepted"'
xcrun stapler validate "$app"
xcrun stapler validate "dist/$prefix-$version.dmg"
codesign --verify --deep --strict "$app"
spctl --assess --type execute "$app"
shasum -a 256 -c dist/SHA256SUMS
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then echo "$tag already exists; increment Assets/version and Assets/build-number." >&2; exit 1; fi
git tag -a "$tag" -m "$prefix $version"
git push origin "$tag"
gh release create "$tag" "dist/$prefix-$version.zip" "dist/$prefix-$version.dmg" dist/SHA256SUMS --repo "$repo" --verify-tag --draft --title "$prefix $version" --notes-file RELEASE_NOTES.md
gh release edit "$tag" --repo "$repo" --draft=false --latest
curl --fail --location --retry 5 --retry-delay 2 "https://github.com/$repo/releases/download/$tag/$prefix-$version.zip" -o dist/published-download.zip
cmp "dist/$prefix-$version.zip" dist/published-download.zip
# Publish the signed feed only after its immutable update archive is publicly downloadable.
if gh release view updates --repo "$repo" >/dev/null 2>&1; then
  gh release upload updates dist/appcast.xml --repo "$repo" --clobber
else
  printf 'Signed Sparkle update feed. Download application installers from the versioned releases.\n' > dist/feed-notes.md
  gh release create updates dist/appcast.xml --repo "$repo" --target "$(git rev-parse HEAD)" --title 'Update feed' --notes-file dist/feed-notes.md --prerelease --latest=false
fi
curl --fail --location --retry 5 --retry-delay 2 "https://github.com/$repo/releases/download/updates/appcast.xml" -o dist/published-appcast.xml
cmp dist/appcast.xml dist/published-appcast.xml
printf 'Published %s and verified its Sparkle feed.\n' "$tag"
