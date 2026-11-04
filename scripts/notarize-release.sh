#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .github/release-contract.env
version="${APP_VERSION:-$DEFAULT_APP_VERSION}"
app="$PWD/.build/$APP_BUNDLE_NAME"
out="$PWD/.build/releases/v$version"
mkdir -p "$out"
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application:.*\(66K3EFBVB6\)/ {print $2; exit}')}"
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  test -n "${APPLE_ID:-}" && test -n "${APPLE_APP_SPECIFIC_PASSWORD:-}"
  auth=(--apple-id "$APPLE_ID" --team-id "$TEAM_IDENTIFIER" --password "$APPLE_APP_SPECIFIC_PASSWORD")
fi
verify_team() {
  codesign --verify --deep --strict "$1"
  test "$(codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$TEAM_IDENTIFIER"
}
verify_team "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$BUNDLE_IDENTIFIER"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" "${auth[@]}" --wait --output-format json > "$out/app-notary.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted"' "$out/app-notary.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
scripts/create-dmg.sh "$app" "$out/$DMG_ASSET_NAME"
codesign --force --sign "$identity" --timestamp "$out/$DMG_ASSET_NAME"
verify_team "$out/$DMG_ASSET_NAME"
xcrun notarytool submit "$out/$DMG_ASSET_NAME" "${auth[@]}" --wait --output-format json > "$out/dmg-notary.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted"' "$out/dmg-notary.json"
xcrun stapler staple "$out/$DMG_ASSET_NAME"
xcrun stapler validate "$out/$DMG_ASSET_NAME"
spctl --assess --type open --context context:primary-signature --verbose=4 "$out/$DMG_ASSET_NAME"
hdiutil verify "$out/$DMG_ASSET_NAME"
shasum -a 256 "$out/$DMG_ASSET_NAME"
python3 - "$out" "$version" <<'PY'
import hashlib, json, pathlib, sys
out, version = pathlib.Path(sys.argv[1]), sys.argv[2]
contract = dict(line.split("=",1) for line in pathlib.Path(".github/release-contract.env").read_text().splitlines() if line and not line.startswith("#"))
with (out/contract["DMG_ASSET_NAME"]).open("rb") as file:
    digest=hashlib.file_digest(file,"sha256").hexdigest()
(out/contract["MANIFEST_ASSET_NAME"]).write_text(json.dumps({
    "version":version, "asset":contract["DMG_ASSET_NAME"], "sha256":digest,
    "bundleIdentifier":contract["BUNDLE_IDENTIFIER"], "teamIdentifier":contract["TEAM_IDENTIFIER"]
}, indent=2)+"\n")
PY
echo "Verified release artifacts: $out"
