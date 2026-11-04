import Foundation

enum UpdateInstaller {
  static var resultURL: URL {
    BuildIdentity.supportDirectory.appendingPathComponent("Updater/install-error.txt")
  }

  static func launch(dmg: URL, target: URL, release: UpdateRelease, directory: URL) throws {
    let script = directory.appendingPathComponent("install-update.sh")
    try installerScript.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), dmg.path,
      target.path, ReleaseContract.bundleIdentifier, release.version, ReleaseContract.appBundleName,
      ReleaseContract.executableName, ReleaseContract.teamIdentifier, release.manifest.sha256,
      directory.path, resultURL.path]
    try process.run()
  }

  // Every path and trust value arrives as a positional argument, never shell source.
  static let installerScript = #"""
  #!/bin/bash
  set -euo pipefail
  PARENT_PID="$1"
  DMG="$2"
  TARGET="$3"
  BUNDLE_ID="$4"
  VERSION="$5"
  APP_BUNDLE="$6"
  EXECUTABLE="$7"
  EXPECTED_TEAM_ID="$8"
  EXPECTED_HASH="$9"
  shift 9
  WORK="$1"
  RESULT="$2"
  MOUNT="$WORK/mount"
  STAGING=""
  STAGED_APP=""
  BACKUP_APP=""
  ATTACHED=0
  SUCCESS=0
  REPLACED=0
  exec >"$WORK/install.log" 2>&1

  cleanup() {
    local code=$?
    trap - EXIT INT TERM
    if [[ "$SUCCESS" != 1 ]]; then
      printf '%s\n' 'Update installation failed; the previous version was retained.' > "$RESULT"
      # rollback: never discard the backup unless the new executable was observed running.
      if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
        if [[ "$REPLACED" == 1 ]]; then
          # Only terminate the exact newly installed executable before rolling back.
          while read -r pid; do
            if [[ "$(/bin/ps -p "$pid" -o comm= 2>/dev/null)" == "$TARGET/Contents/MacOS/$EXECUTABLE" ]]; then
              /bin/kill "$pid" 2>/dev/null || true
            fi
          done < <(/usr/bin/pgrep -x "$EXECUTABLE" || true)
          /bin/mv "$TARGET" "$STAGING/failed.app" 2>/dev/null || true
        fi
        /bin/mv "$BACKUP_APP" "$TARGET" 2>/dev/null || true
      fi
      if [[ -d "$TARGET" ]]; then /usr/bin/open "$TARGET" 2>/dev/null || true; fi
    fi
    if [[ "$ATTACHED" == 1 ]]; then /usr/bin/hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; fi
    # If rollback itself failed, keep its only remaining backup for recovery.
    if [[ -n "$STAGING" && ! -d "$BACKUP_APP" ]]; then /bin/rm -rf "$STAGING"; fi
    /bin/rm -rf "$WORK"
    exit "$code"
  }
  trap cleanup EXIT
  trap 'exit 1' INT TERM
  fail() { echo "Updater: $*"; exit 1; }

  verify_app() {
    local app="$1" info="$1/Contents/Info.plist" details team requirement
    [[ -d "$app" && ! -L "$app" ]] || fail 'Missing app bundle'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "$BUNDLE_ID" ]] || fail 'Bundle mismatch'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$VERSION" ]] || fail 'Version mismatch'
    [[ -x "$app/Contents/MacOS/$EXECUTABLE" ]] || fail 'Missing executable'
    /usr/bin/codesign --verify --deep --strict "$app" || fail 'Invalid app signature'
    details=$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1)
    team=$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    [[ "$team" == "$EXPECTED_TEAM_ID" ]] || fail 'Publisher mismatch'
    requirement="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    /usr/bin/codesign --verify --strict -R "=$requirement" "$app" || fail 'Designated requirement mismatch'
    /usr/sbin/spctl --assess --type execute --verbose=4 "$app" || fail 'Gatekeeper rejected app'
  }

  [[ "$WORK" == "$(/usr/bin/dirname "$DMG")" && -d "$TARGET" && ! -L "$TARGET" ]] || fail 'Invalid installation paths'
  [[ "$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')" == "$EXPECTED_HASH" ]] || fail 'Checksum mismatch'
  /usr/bin/codesign --verify --strict "$DMG" || fail 'Invalid DMG signature'
  details=$(/usr/bin/codesign -dv --verbose=4 "$DMG" 2>&1)
  [[ "$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^TeamIdentifier=//p')" == "$EXPECTED_TEAM_ID" ]] || fail 'DMG publisher mismatch'
  /usr/sbin/spctl --assess --type open --context context:primary-signature "$DMG" || fail 'Gatekeeper rejected DMG'
  /bin/mkdir "$MOUNT"
  /usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG" || fail 'Could not mount DMG'
  ATTACHED=1
  verify_app "$MOUNT/$APP_BUNDLE"
  STAGING=$(/usr/bin/mktemp -d "$(/usr/bin/dirname "$TARGET")/.macpurge-update.XXXXXXXX")
  STAGED_APP="$STAGING/$APP_BUNDLE"
  BACKUP_APP="$STAGING/previous.app"
  /usr/bin/ditto "$MOUNT/$APP_BUNDLE" "$STAGED_APP"
  verify_app "$STAGED_APP"
  # Wait for the app to quit normally; never interrupt an ongoing user operation.
  for ((i=0; i<300; i++)); do
    /bin/kill -0 "$PARENT_PID" 2>/dev/null || break
    /bin/sleep 0.1
  done
  /bin/kill -0 "$PARENT_PID" 2>/dev/null && fail 'The app is still running'
  /bin/mv "$TARGET" "$BACKUP_APP"
  /bin/mv "$STAGED_APP" "$TARGET"
  REPLACED=1
  /usr/bin/open "$TARGET" || fail 'Could not launch update'
  launchConfirmation=0
  for ((i=0; i<100; i++)); do
    while read -r pid; do
      if [[ "$(/bin/ps -p "$pid" -o comm= 2>/dev/null)" == "$TARGET/Contents/MacOS/$EXECUTABLE" ]]; then
        launchConfirmation=$((launchConfirmation+1))
      fi
    done < <(/usr/bin/pgrep -x "$EXECUTABLE" || true)
    [[ "$launchConfirmation" -ge 3 ]] && break
    /bin/sleep 0.3
  done
  [[ "$launchConfirmation" -ge 3 ]] || fail 'New executable did not remain running'
  /bin/rm -rf "$BACKUP_APP"
  /bin/rm -f "$RESULT"
  SUCCESS=1
  """#
}
