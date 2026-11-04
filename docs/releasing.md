# MacPurge releases

`.github/release-contract.env` defines the repository, production bundle identifier, publisher and asset names. `scripts/validate-release-contract.py` checks these against the app, widget and updater.

The manual **Release MacPurge** workflow tests the source, builds a universal app, signs its widget and app with hardened runtime, notarizes and staples the app, builds the Finder DMG, then signs, notarizes and staples the DMG. Publication happens only after strict signatures, exact TeamIdentifier, Gatekeeper, staple validation and disk-image verification pass.

The first release uses `DEFAULT_APP_VERSION`; subsequent runs default to the next patch version. The optional workflow version input must be newer than all existing release tags. Tag `vX.Y.Z`, app version and manifest version must match.

Required Actions secrets (names only):

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

Run the user-specific Developer ID skill's readiness script before dispatching. Never commit certificate material or generated release artifacts.

For local preparation, `APP_VERSION=X.Y.Z scripts/build-app.sh` creates a signed universal `.build/MacPurge.app`. `NOTARY_KEYCHAIN_PROFILE=<existing profile> APP_VERSION=X.Y.Z scripts/notarize-release.sh` produces verified `.build/releases/vX.Y.Z/MacPurge.dmg` and its companion manifest. Without a Keychain profile, the notarization script reads `APPLE_ID` and `APPLE_APP_SPECIFIC_PASSWORD` from the environment.

The updater expects `MacPurge.dmg` and `MacPurge.dmg.update.json` in the same public release. The manifest contains `version`, `asset`, `sha256`, `bundleIdentifier` and `teamIdentifier`. It detects damaged or mismatched assets; exact Developer ID and Gatekeeper checks authenticate the publisher.

Prototype preferences are imported once into the production bundle's defaults domain. Scan history and Trash restore journals keep their existing application-support paths.
