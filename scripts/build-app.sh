#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source .github/release-contract.env
python3 scripts/validate-release-contract.py
version="${APP_VERSION:-$DEFAULT_APP_VERSION}"
build="${APP_BUILD_NUMBER:-20}"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application:.*\(66K3EFBVB6\)/ {print $2; exit}')}"
[[ -n "$identity" && "$identity" != "-" ]]
command -v xcodegen >/dev/null
xcodegen generate >/dev/null
derived="$root/.build/release-xcode"
xcodebuild -quiet -project MacPurge.xcodeproj -scheme MacPurge -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  ARCHS="${MACPURGE_ARCHS:-arm64 x86_64}" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGNING_ALLOWED=NO build
app="$root/.build/$APP_BUNDLE_NAME"
if [[ -e "$app" ]]; then /bin/rm -rf "$app"; fi
ditto "$derived/Build/Products/Release/$APP_BUNDLE_NAME" "$app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon.icns' "$app/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon.icns' "$app/Contents/Info.plist"
widget="$app/Contents/PlugIns/MacPurgeWidget.appex"
test -x "$widget/Contents/MacOS/MacPurgeWidget"
test -f "$app/Contents/Resources/Metadata.appintents/extract.actionsdata"
test -f "$app/Contents/Resources/THIRD-PARTY-NOTICES"
codesign --force --sign "$identity" --options runtime --timestamp --entitlements Packaging/widget-entitlements.plist "$widget"
codesign --force --sign "$identity" --options runtime --timestamp --entitlements Packaging/app-entitlements.plist "$app"
for bundle in "$widget" "$app"; do
  codesign --verify --deep --strict "$bundle"
  details="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
  test "$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')" = "$TEAM_IDENTIFIER"
  printf '%s\n' "$details" | grep -E 'flags=.*runtime' >/dev/null
done
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$BUNDLE_IDENTIFIER"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
codesign --verify --strict -R="anchor apple generic and identifier \"$BUNDLE_IDENTIFIER\" and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$app"
for arch in ${MACPURGE_ARCHS:-arm64 x86_64}; do
  lipo "$app/Contents/MacOS/$EXECUTABLE_NAME" -verify_arch "$arch"
  lipo "$widget/Contents/MacOS/MacPurgeWidget" -verify_arch "$arch"
done
echo "Signed $APP_BUNDLE_NAME $version ($build)"
