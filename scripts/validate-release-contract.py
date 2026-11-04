#!/usr/bin/env python3
import pathlib, re
root = pathlib.Path(__file__).resolve().parent.parent
contract = dict(line.split("=", 1) for line in (root/".github/release-contract.env").read_text().splitlines() if line and not line.startswith("#"))
assert contract["GITHUB_OWNER"] == "burakereno"
assert contract["TEAM_IDENTIFIER"] == "66K3EFBVB6"
assert contract["MANIFEST_ASSET_NAME"] == contract["DMG_ASSET_NAME"] + ".update.json"
source = (root/"Sources/MacPurge/ReleaseContract.swift").read_text()
mapping = {"GITHUB_OWNER":"owner","GITHUB_REPO":"repository","APP_NAME":"appName","APP_BUNDLE_NAME":"appBundleName",
           "EXECUTABLE_NAME":"executableName","BUNDLE_IDENTIFIER":"bundleIdentifier","TEAM_IDENTIFIER":"teamIdentifier",
           "DMG_ASSET_NAME":"assetName","MANIFEST_ASSET_NAME":"manifestName"}
for key, swift_key in mapping.items():
    assert re.search(r'static let ' + swift_key + r' = "' + re.escape(contract[key]) + r'"', source), key + " differs from updater"
project = (root/"project.yml").read_text()
assert "PRODUCT_BUNDLE_IDENTIFIER: " + contract["BUNDLE_IDENTIFIER"] + "\n" in project
assert "PRODUCT_BUNDLE_IDENTIFIER: " + contract["BUNDLE_IDENTIFIER"] + ".widget\n" in project
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", contract["DEFAULT_APP_VERSION"])
print("Release contract matches the app, widget and updater.")
