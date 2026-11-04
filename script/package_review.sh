#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Production-package validation; development bundles use a different identity.
app="${1:-$PWD/.build/MacPurge.app}"
test -d "$app"
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/macpurge-review.XXXXXXXX")"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then hdiutil detach "$scratch/mount" >/dev/null; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
mkdir "$scratch/contents" "$scratch/mount"
ditto "$app" "$scratch/contents/MacPurge.app"
ln -s /Applications "$scratch/contents/Applications"
hdiutil create -quiet -srcfolder "$scratch/contents" -volname "MacPurge $version" -format UDZO -fs HFS+ "$scratch/MacPurge.dmg"
hdiutil verify -quiet "$scratch/MacPurge.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$scratch/mount" "$scratch/MacPurge.dmg" >/dev/null
mounted=1
codesign --verify --deep --strict "$scratch/mount/MacPurge.app"
"$app/Contents/MacOS/MacPurge" --verify-package "$scratch/mount/MacPurge.app"
hdiutil detach "$scratch/mount" >/dev/null
mounted=0
mv "$scratch/MacPurge.dmg" "dist/MacPurge-$version-kontrol.dmg"
shasum -a 256 "dist/MacPurge-$version-kontrol.dmg"
