#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mode="${1:-run}"
case "$mode" in run|--build|--verify|--debug|--logs|--telemetry) ;; *) exit 2 ;; esac
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null; fi
xcodebuild -quiet -project MacPurge.xcodeproj -scheme MacPurge -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/control-xcode CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
stage="$(mktemp -d "$root/dist/.review-XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/MacPurge.app"
ditto .build/control-xcode/Build/Products/Release/MacPurge.app "$app"
widget="$app/Contents/PlugIns/MacPurgeWidget.appex"
test -f "$app/Contents/Resources/Metadata.appintents/extract.actionsdata"
test -f "$widget/Contents/MacOS/MacPurgeWidget"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon.icns' "$app/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon.icns' "$app/Contents/Info.plist"
local_identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ && /66K3EFBVB6/ {print $2; exit}')"
identity="${MACPURGE_SIGN_IDENTITY:-${local_identity:--}}"
codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements Packaging/widget-entitlements.plist "$widget"
codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements Packaging/app-entitlements.plist "$app"
codesign --verify --deep --strict "$app"
bundle="$root/dist/MacPurge.app"
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
