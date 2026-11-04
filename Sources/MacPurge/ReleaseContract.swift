// Keep in sync with .github/release-contract.env; scripts/validate-release-contract.py checks this.
enum ReleaseContract {
  static let owner = "burakereno"
  static let repository = "macpurge"
  static let appName = "MacPurge"
  static let appBundleName = "MacPurge.app"
  static let executableName = "MacPurge"
  static let bundleIdentifier = "com.burakerenoglu.macpurge"
  static let teamIdentifier = "66K3EFBVB6"
  static let assetName = "MacPurge.dmg"
  static let manifestName = "MacPurge.dmg.update.json"
}

import Foundation

enum ReleasePreferences {
  static func migrate() {
    guard Bundle.main.bundleIdentifier == ReleaseContract.bundleIdentifier,
      !UserDefaults.standard.bool(forKey: "didImportPrototypePreferences") else { return }
    let prefs = UserDefaults.standard
    let previous = prefs.persistentDomain(forName: "com.burakerenoglu.macpurge.prototype") ?? [:]
    let current = prefs.persistentDomain(forName: ReleaseContract.bundleIdentifier) ?? [:]
    for key in [
      "reviewLanguage", "liveScan.selectedProjectPaths", "scanExcludedPaths", "activityRetentionDays",
      "hiddenRows", "keepsScanArchive", "scanProtectedLocations", "appIconLocation", "showsDiskMenu",
      "scheduledScan", "alertsEnabled", "lowSpaceGB", "weeklySummary", "growthAlerts",
    ] where current[key] == nil {
      if let value = previous[key] { prefs.set(value, forKey: key) }
    }
    prefs.set(true, forKey: "didImportPrototypePreferences")
  }
}
