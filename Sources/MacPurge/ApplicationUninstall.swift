import AppKit
import Darwin
import Foundation
import Security

#if SWIFT_PACKAGE
import MacPurgeCore
#endif

/// An uninstall review grants access to exact app locations. Storage attribution is read-only
/// and can describe broader directories, so it is never used to authorize these moves.
struct ApplicationUninstall: Codable, Hashable, Sendable {
  let app: ApplicationIdentity
  let helperIDs: Set<String>

  enum Kind: Sendable {
    case bundle, cache, preferences, data, logs, shared, background

    var title: String {
      switch self {
      case .bundle: "App bundle"
      case .cache: "Caches"
      case .preferences: "Settings and state"
      case .data: "Application data"
      case .logs: "Logs and crash reports"
      case .shared: "Shared container"
      case .background: "Background component"
      }
    }

    var warning: String {
      switch self {
      case .bundle: "The application will be moved to the Trash."
      case .cache, .logs: "Cached files or diagnostic history will be removed."
      default: "Settings, profiles or local files stored by the application may be lost when you empty the Trash."
      }
    }
  }

  struct Match: Sendable {
    let kind: Kind
    var byName = false
    var explanation: String { byName ? "Matches the application name. Verify that this file belongs to the app." : kind.warning }
  }

  struct Candidate: Sendable {
    let url: URL
    let match: Match
    var blocked: String? = nil
  }

  struct Row: Identifiable, Sendable {
    let candidate: Candidate
    var target: TrashTarget? = nil
    var id: String { candidate.url.path }
    var title: String { target?.name ?? candidate.url.lastPathComponent }
    var action: CleanupAction {
      if let target { return .move(.review, bytes: target.snapshot.reclaimableBytes) }
      return .unavailable(.blocked(ReviewLanguage.text(candidate.blocked ?? "Bu konum Çöp’e taşınamaz.")))
    }
  }

  struct Inspection: Sendable {
    let rows: [Row]
    var unreadable: [String] = []
    var blocker: String? = nil

    var selectableIDs: [String] {
      guard blocker == nil else { return [] }
      return rows.compactMap { $0.target?.id }
    }
  }

  private static let libraryScopes: [(String, Kind)] = [
    ("Application Support", .data), ("Application Scripts", .data), ("Containers", .data),
    ("Caches", .cache), ("WebKit", .data), ("HTTPStorages", .data), ("Cookies", .data),
    ("Preferences", .preferences), ("Preferences/ByHost", .preferences),
    ("Saved Application State", .preferences),
    ("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", .preferences),
    ("Logs", .logs), ("Logs/DiagnosticReports", .logs), ("Application Support/CrashReporter", .logs),
  ]
  private static let aliases: [String: [String]] = [
    "com.google.chrome": ["Application Support/Google/Chrome", "Caches/Google/Chrome"],
    "com.microsoft.vscode": ["Application Support/Code", "Caches/Code", "Logs/Code"],
    "com.todesktop.230313mzl4w4u92": ["Application Support/Cursor", "Caches/Cursor"],
    "com.anthropic.claudefordesktop": ["Application Support/Claude", "Caches/Claude"],
    "com.openai.codex": ["Application Support/Codex", "Caches/Codex"],
  ]
  private static let recentDocuments = "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
  private static let sharedNames: Set<String> = [
    "adobe", "apple", "crashreporter", "diagnosticreports", "google", "jetbrains", "microsoft", "mozilla",
    "macpurge", "macpurge dev",
  ]
  private var keys: Set<String> { Set(helperIDs.map { $0.lowercased() } + [app.bundleID.lowercased()]) }
  private var names: Set<String> {
    [app.name.lowercased(), URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent.lowercased()]
  }
  var bundleURL: URL { URL(fileURLWithPath: app.path) }

  static func protectedReason(_ app: ApplicationIdentity) -> String? {
    let id = app.bundleID.lowercased()
    if app.path.hasPrefix("/System/") { return "macOS protects this application." }
    if id == "com.burakerenoglu.macpurge" || id.hasPrefix("com.burakerenoglu.macpurge.")
      || app.path == Bundle.main.bundlePath {
      return "MacPurge protects its own installation and data."
    }
    return nil
  }

  private static func validIdentifier(_ value: String) -> Bool {
    value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
      && value.contains(".") && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
  }

  func permits(_ url: URL, home: URL) -> Bool {
    guard url.isFileURL, Self.protectedReason(app) == nil, Self.validIdentifier(app.bundleID),
      url.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
      ["/Applications", home.appending(path: "Applications").path].contains(where: { root in
        guard app.path.hasPrefix(root + "/"), bundleURL.pathExtension.lowercased() == "app" else { return false }
        let parts = app.path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
          && !parts.dropLast().contains { $0.lowercased().hasSuffix(".app") }
      })
    else { return false }
    return url.path == app.path || (!app.bundleID.lowercased().hasPrefix("com.apple.") && matchData(url, home: home) != nil)
  }

  private func matchData(_ url: URL, home: URL) -> Match? {
    let library = home.appending(path: "Library").path + "/"
    guard url.path.hasPrefix(library) else { return nil }
    let relative = String(url.path.dropFirst(library.count))
    let parent = (relative as NSString).deletingLastPathComponent
    let name = url.lastPathComponent.lowercased()
    if Self.aliases[app.bundleID.lowercased()]?.contains(relative) == true {
      return Match(kind: relative.hasPrefix("Caches/") ? .cache : .data, byName: true)
    }
    guard let kind = Self.libraryScopes.first(where: { $0.0 == parent })?.1,
      !Self.sharedNames.contains(name), name != "com.apple.sharedfilelist", name != "com.apple.tcc"
    else { return nil }
    switch parent {
    case "Preferences": return keys.contains(strip(name, suffix: ".plist")) && name.hasSuffix(".plist") ? Match(kind: kind) : nil
    case "Preferences/ByHost":
      let stem = strip(name, suffix: ".plist")
      guard name.hasSuffix(".plist"), let dot = stem.lastIndex(of: "."),
        UUID(uuidString: String(stem[stem.index(after: dot)...])) != nil,
        keys.contains(String(stem[..<dot])) else { return nil }
      return Match(kind: kind)
    case "Saved Application State":
      return keys.contains(strip(name, suffix: ".savedstate")) && name.hasSuffix(".savedstate") ? Match(kind: kind) : nil
    case "Cookies", "HTTPStorages":
      return keys.contains(name) || keys.contains(strip(name, suffix: ".binarycookies")) ? Match(kind: kind) : nil
    case Self.recentDocuments:
      return [".sfl2", ".sfl3", ".sfl4"].contains { name.hasSuffix($0) && keys.contains(strip(name, suffix: $0)) } ? Match(kind: kind) : nil
    case "Application Support/CrashReporter":
      guard name.hasSuffix(".plist") else { return nil }
      let stem = strip(name, suffix: ".plist")
      return names.contains { stem.hasPrefix($0 + "_") && UUID(uuidString: String(stem.dropFirst($0.count + 1))) != nil }
        ? Match(kind: kind, byName: true) : nil
    case "Logs/DiagnosticReports":
      return names.contains { value in
        guard name.hasPrefix(value + "_"), [".ips", ".crash", ".hang", ".spin"].contains(where: name.hasSuffix)
        else { return false }
        return name.dropFirst(value.count + 1).first?.isNumber == true
      } ? Match(kind: kind, byName: true) : nil
    default:
      if keys.contains(name) { return Match(kind: kind) }
      if parent == "Caches", name.hasSuffix(".shipit"), keys.contains(strip(name, suffix: ".shipit")) {
        return Match(kind: kind)
      }
      if ["Caches", "Logs", "Application Support"].contains(parent), names.contains(name), !name.hasPrefix("com.apple.") {
        return Match(kind: kind, byName: true)
      }
      return nil
    }
  }

  private func strip(_ value: String, suffix: String) -> String {
    value.hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
  }

  func verifyBundle() throws {
    guard let id = ApplicationInventory.metadata(at: bundleURL)?["CFBundleIdentifier"] as? String,
      id == app.bundleID else { throw CleanupFailure("The application has changed. Scan its files again.") }
  }

  func verifyIdle() async throws {
    let ids = keys
    let prefix = app.path + "/"
    let running = await MainActor.run {
      NSWorkspace.shared.runningApplications.contains {
        !$0.isTerminated && (ids.contains($0.bundleIdentifier?.lowercased() ?? "")
          || $0.executableURL?.path.hasPrefix(prefix) == true)
      }
    }
    guard !running else { throw CleanupFailure("Quit the application and its helpers, then try again.", inUse: true) }
    let processes = try await InventoryCommand.output("/bin/ps", ["-axww", "-o", "comm="])
    guard !String(decoding: processes, as: UTF8.self).split(separator: "\n").contains(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
    })
    else { throw CleanupFailure("Quit the application and its helpers, then try again.", inUse: true) }
  }

  func copiesInstalled(in installed: [ApplicationInventory.Installed]) async -> Bool {
    let id = app.bundleID
    let path = app.path
    if installed.contains(where: { $0.id != path && $0.identity.bundleID.caseInsensitiveCompare(id) == .orderedSame }) {
      return true
    }
    return await MainActor.run {
      NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).contains { url in
        url.path != path && url.path != "/System/Volumes/Data" + path
          && !url.path.hasPrefix("/Volumes/") && !url.path.contains("/.Trash/")
          && FileManager.default.fileExists(atPath: url.path)
      }
    }
  }

  @concurrent static func catalog(home: URL, exclusions: [URL]) async throws -> [ApplicationInventory.Installed] {
    try ScanExclusions.$current.withValue(ScanExclusions(paths: exclusions.map(\.path))) {
      try ApplicationInventory.installed(home: home, volumes: ScanVolumes(home: home, projects: []))
        .sorted {
          let order = $0.identity.name.localizedStandardCompare($1.identity.name)
          return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
  }

  static func identify(_ app: ApplicationIdentity, volumes: ScanVolumes) throws -> (Self, groups: Set<String>) {
    let bundle = URL(fileURLWithPath: app.path)
    let directories = ["PlugIns", "XPCServices", "Library/LoginItems", "Library/LaunchServices", "Library/Helpers"]
    let helpers = try directories.flatMap {
      try DeveloperDataInventory.children(bundle.appending(path: "Contents/" + $0), volumes: volumes)
        .filter { $0.directory && ["app", "appex", "xpc"].contains($0.url.pathExtension.lowercased()) }
    }
    var ids = Set<String>()
    var groups = signedGroups(bundle)
    for helper in helpers {
      try Task.checkCancellation()
      guard let id = ApplicationInventory.metadata(at: helper.url)?["CFBundleIdentifier"] as? String,
        validIdentifier(id), id.lowercased().hasPrefix(app.bundleID.lowercased() + ".") else { continue }
      ids.insert(id)
      groups.formUnion(signedGroups(helper.url))
    }
    return (Self(app: app, helperIDs: ids), groups)
  }

  private static func signedGroups(_ url: URL) -> Set<String> {
    var code: SecStaticCode?
    var info: CFDictionary?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let values = info as? [String: Any], let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      let groups = entitlements["com.apple.security.application-groups"] as? [String]
    else { return [] }
    return Set(groups.filter(Self.validIdentifier))
  }

  func sharedData(_ url: URL, home: URL, installed: [ApplicationInventory.Installed]) -> Bool {
    guard let match = matchData(url, home: home) else { return false }
    return installed.contains { item in
      guard item.id != app.path,
        let otherMatch = Self(app: item.identity, helperIDs: []).matchData(url, home: home) else { return false }
      return match.byName || !otherMatch.byName
    }
  }

  func candidates(home: URL, groups: Set<String>, installed: [ApplicationInventory.Installed],
                  hasOtherCopy: Bool) throws -> ([Candidate], unreadable: [String]) {
    let library = home.appending(path: "Library")
    var rows: [Candidate] = []
    var unreadable: [String] = []
    func entries(_ parent: URL) throws -> [DirectoryIndex.Entry] {
      do { return try DirectoryIndex.children(of: parent) }
      catch let error as DirectoryIndex.Problem {
        if error.code != ENOENT { unreadable.append(parent.path) }
        return []
      }
    }
    func append(_ url: URL) {
      guard let match = matchData(url, home: home) else { return }
      let blocked: String?
      if hasOtherCopy || sharedData(url, home: home, installed: installed) {
        blocked = "Another installed application may use this file."
      } else if app.bundleID.lowercased().hasPrefix("com.apple.") {
        blocked = "macOS application data is available for inspection only."
      } else {
        blocked = nil
      }
      rows.append(.init(url: url, match: match, blocked: blocked))
    }

    for (folder, _) in Self.libraryScopes {
      for entry in try entries(library.appending(path: folder)) { append(entry.url) }
    }
    for relative in Self.aliases[app.bundleID.lowercased()] ?? [] {
      let url = library.appending(path: relative)
      if relative.split(separator: "/").count > 2,
        try entries(url.deletingLastPathComponent()).contains(where: { $0.url.path == url.path }) {
        append(url)
      }
    }
    if !groups.isEmpty {
      // The app's signed entitlements name these containers. They may also belong to other apps.
      let lowerGroups = Set(groups.map { $0.lowercased() })
      let parent = library.appending(path: "Group Containers")
      for entry in try entries(parent) where lowerGroups.contains(entry.url.lastPathComponent.lowercased()) {
        rows.append(.init(url: entry.url, match: .init(kind: .shared),
          blocked: "Other applications can use this shared container."))
      }
    }
    let privileged = ApplicationInventory.metadata(at: bundleURL)?["SMPrivilegedExecutables"] as? [String: String] ?? [:]
    let serviceIDs = keys.union(privileged.keys.map { $0.lowercased() })
    for parent in [library.appending(path: "LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"),
      URL(fileURLWithPath: "/Library/LaunchDaemons"), URL(fileURLWithPath: "/Library/PrivilegedHelperTools")] {
      for entry in try entries(parent) {
        let name = entry.url.lastPathComponent.lowercased()
        guard serviceIDs.contains(strip(name, suffix: ".plist")) else { continue }
        rows.append(.init(url: entry.url, match: .init(kind: .background),
          blocked: "Manage this background component with the developer’s uninstaller."))
      }
    }
    var seen = Set<String>()
    return (rows.filter { seen.insert($0.url.path).inserted }, Array(Set(unreadable)).sorted())
  }
}
