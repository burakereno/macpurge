#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mode="${1:-run}"
case "$mode" in run|--build|--verify|--debug|--logs|--telemetry) ;; *) exit 2 ;; esac
if [[ ! -f Artwork/AppIcon-Dev.icns || Artwork/AppIcon-2048.png -nt Artwork/AppIcon-Dev.icns || script/generate_app_icon.swift -nt Artwork/AppIcon-Dev.icns ]]; then
    swift script/generate_app_icon.swift --development
fi
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null; fi
xcodebuild -quiet -project MacPurge.xcodeproj -scheme MacPurge -configuration Development \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/development-xcode CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
stage="$(mktemp -d "$root/dist/.review-XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/MacPurge Dev.app"
ditto '.build/development-xcode/Build/Products/Development/MacPurge Dev.app' "$app"
widget="$app/Contents/PlugIns/MacPurgeWidget.appex"
test -f "$app/Contents/Resources/Metadata.appintents/extract.actionsdata"
test -f "$widget/Contents/MacOS/MacPurgeWidget"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon-Dev.icns' "$app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = com.burakerenoglu.macpurge.dev
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget/Contents/Info.plist")" = com.burakerenoglu.macpurge.dev.widget
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")" = 'MacPurge Dev'
local_identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ && /66K3EFBVB6/ {print $2; exit}')"
identity="${MACPURGE_SIGN_IDENTITY:-${local_identity:--}}"
# Xcode's debug entry point loads these libraries with runtime validation.
# Sign nested code with the same identity before sealing the widget and app.
while IFS= read -r -d '' library; do
    codesign --force --sign "$identity" --options runtime --timestamp=none "$library"
done < <(find "$app/Contents" -type f -name '*.dylib' -print0)
codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements Packaging/dev-widget-entitlements.plist "$widget"
codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements Packaging/dev-app-entitlements.plist "$app"
codesign --verify --deep --strict "$app"
bundle="$root/dist/MacPurge Dev.app"
for pid in $(pgrep -x MacPurge || true); do
    if [[ "$(ps -p "$pid" -o comm=)" == "$bundle/Contents/MacOS/MacPurge" ]]; then kill "$pid" 2>/dev/null || true; fi
done
if [[ -e "$bundle" ]]; then mv "$bundle" "$stage/prior.app"; fi
mv "$app" "$bundle"
case "$mode" in
    --build) ;;
    --debug) exec xcrun lldb -- "$bundle/Contents/MacOS/MacPurge" ;;
    --verify) open -n "$bundle"; sleep 1; pgrep -x MacPurge ;;
    --logs|--telemetry) open -n "$bundle"; exec /usr/bin/log stream --info --predicate 'process == "MacPurge"' ;;
    run) open -n "$bundle" ;;
esac
