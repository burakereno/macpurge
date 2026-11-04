# MacPurge

A native macOS app for understanding storage use and reviewing cleanup candidates.

MacPurge measures known storage locations and selected project folders. Supported cleanup actions show a preview before moving files to the Trash. Restore options stay separate from scan-history retention.

## Install

Download **MacPurge.dmg** from [Releases](https://github.com/burakereno/macpurge/releases/latest), open it and drag MacPurge into Applications. Requires macOS 14 or later; release builds include Intel and Apple Silicon.

## Build

Requires Xcode 26 or later (Swift 6.2+) and XcodeGen.

```sh
brew install xcodegen
swift test
./script/build_and_run.sh
```

The local run script builds **MacPurge Dev** with an orange **DEV** icon badge,
bundle identifier `com.burakerenoglu.macpurge.dev`, and separate preferences,
history, Trash receipts and widget data. Xcode's Run action also uses the
Development configuration. Production archives and GitHub releases use the
normal MacPurge identity and icon. Development builds cannot install production
updates over themselves.

## Releases and updates

The app checks public GitHub Releases and validates the matching update manifest, SHA-256, exact Developer ID publisher and Gatekeeper assessment. Installation stages a new app and retains the previous app until the replacement is observed running.

Release values live in `.github/release-contract.env`. See [release instructions](docs/releasing.md).
