import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// Chromium cache names and layout checks are adapted from Purge's
/// CacheDiscoveryPaths at 0a05ed44b415f58fa0709ba44d702d6d26914c1a.
/// See THIRD-PARTY-NOTICES for Jithin Sabu's MIT license.
struct AppCacheRule: Hashable, Sendable {
  let name: String
  let bundle: String
  var caches: [String] = []
  var support: [String] = []
  var container = false

  private static let catalog: [Self] = [
    .init(name: "Codex", bundle: "com.openai.codex", caches: ["Codex", "com.openai.codex"], support: ["Codex"]),
    .init(name: "Figma", bundle: "com.figma.Desktop", caches: ["com.figma.Desktop"], support: ["Figma"]),
    .init(name: "Framer", bundle: "com.framer.electron", caches: ["com.framer.electron", "com.framer.electron.ShipIt"], support: ["Framer"]),
    .init(name: "Google Chrome", bundle: "com.google.Chrome", caches: ["Google/Chrome"], support: ["Google/Chrome"]),
    .init(name: "Brave Browser", bundle: "com.brave.Browser", caches: ["BraveSoftware/Brave-Browser"], support: ["BraveSoftware/Brave-Browser"]),
    .init(name: "Chromium", bundle: "org.chromium.Chromium", caches: ["Chromium"], support: ["Chromium"]),
    .init(name: "Microsoft Edge", bundle: "com.microsoft.edgemac", caches: ["Microsoft Edge"], support: ["Microsoft Edge"]),
    .init(name: "Vivaldi", bundle: "com.vivaldi.Vivaldi", caches: ["Vivaldi"], support: ["Vivaldi"]),
    .init(name: "Arc", bundle: "company.thebrowser.Browser", caches: ["company.thebrowser.Browser", "Arc"], support: ["Arc"]),
    .init(name: "Dia", bundle: "company.thebrowser.dia", caches: ["company.thebrowser.dia"], support: ["Dia"]),
    .init(name: "Firefox", bundle: "org.mozilla.firefox", caches: ["Firefox"]),
    .init(name: "Slack", bundle: "com.tinyspeck.slackmacgap", caches: ["com.tinyspeck.slackmacgap"], support: ["Slack"], container: true),
    .init(name: "Discord", bundle: "com.hnc.Discord", caches: ["com.hnc.Discord"], support: ["discord"]),
    .init(name: "Notion", bundle: "notion.id", caches: ["notion.id"], support: ["Notion"]),
    .init(name: "Obsidian", bundle: "md.obsidian", caches: ["md.obsidian"], support: ["obsidian"]),
    .init(name: "ChatGPT", bundle: "com.openai.chat", caches: ["com.openai.chat"], container: true),
    .init(name: "Claude", bundle: "com.anthropic.claudefordesktop", caches: ["com.anthropic.claudefordesktop"], support: ["Claude"]),
    .init(name: "Telegram", bundle: "ru.keepcoder.Telegram", caches: ["ru.keepcoder.Telegram"]),
    .init(name: "Zoom", bundle: "us.zoom.xos", caches: ["us.zoom.xos"], container: true),
    .init(name: "Spotify", bundle: "com.spotify.client", caches: ["com.spotify.client"]),
    .init(name: "Blender", bundle: "org.blenderfoundation.blender", caches: ["Blender", "org.blenderfoundation.blender"]),
    .init(name: "Purge", bundle: "io.getpurge.app", caches: ["io.getpurge.app"]),
  ]

  // Offline web apps and profile state must stay out of a cleanup target even
  // when a vendor puts them under an otherwise known cache path.
  private static let protectedEntries: Set<String> = [
    "service worker", "cachestorage", "indexeddb", "local storage", "session storage",
    "local state", "cookies", "cookies-journal", "login data", "history", "bookmarks",
    "preferences", "secure preferences", "auth-token.json", ".git",
  ]

  static func accepts(_ entry: String) -> Bool {
    !protectedEntries.contains(entry.lowercased())
  }

  private static let direct = Set([
    "Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "DawnCache",
    "DawnWebGPUCache", "DawnGraphiteCache", "GraphiteDawnCache", "component_crx_cache",
  ])
  private static let profile = direct.subtracting(["component_crx_cache", "GrShaderCache"])
  private static let cachesByPath = Dictionary(uniqueKeysWithValues: catalog.flatMap { rule in
    rule.cachePaths.map { ($0, rule) }
  })
  private static let supportByPath = Dictionary(uniqueKeysWithValues: catalog.flatMap { rule in
    rule.support.map { ("Library/Application Support/" + $0, rule) }
  })

  private var cachePaths: [String] {
    caches.map { "Library/Caches/" + $0 }
      + (container ? ["Library/Containers/" + bundle + "/Data/Library/Caches"] : [])
  }

  /// Match the scope independently of existence so Trash receipts can be restored.
  static func at(_ url: URL, home: URL) -> Self? {
    guard url.path.hasPrefix(home.path + "/") else { return nil }
    let path = String(url.path.dropFirst(home.path.count + 1))
    return cachesByPath[path] ?? chromium(path)?.rule
  }

  private static func chromium(_ path: String) -> (rule: Self, storage: String)? {
    let parts = path.components(separatedBy: "/")
    guard let leaf = parts.last, direct.contains(leaf),
      !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") }) else { return nil }
    let parents = Array(parts.dropLast())
    for (base, rule) in supportByPath where path.hasPrefix(base + "/") {
      let suffix = Array(parents.dropFirst(base.components(separatedBy: "/").count))
      guard suffix.isEmpty || (suffix.count == 1 && suffix[0] == "User Data")
        || isProfile(suffix, leaf: leaf) else { return nil }
      return (rule, parents.joined(separator: "/"))
    }
    return nil
  }

  private static func isProfile(_ suffix: [String], leaf: String) -> Bool {
    guard profile.contains(leaf), let name = suffix.last else { return false }
    if suffix.count == 2, suffix[0] == "Partitions" { return true }
    if suffix.count == 2, suffix[0] == "DesktopProfile" {
      return name.wholeMatch(of: /v[0-9]+/) != nil
    }
    guard suffix.count == 1 || (suffix.count == 2 && suffix[0] == "User Data") else { return false }
    return name == "Default" || name == "Guest Profile"
      || name.wholeMatch(of: /Profile [0-9]+/) != nil || name == "codex-browser-app"
  }

  func validate(_ url: URL, home: URL) throws {
    guard Self.at(url, home: home) == self else {
      throw CleanupFailure("The app cache location could not be verified.")
    }
    let device = try TrashFiles.directory(home, enumerate: false) { _, info in info.st_dev }
    try TrashFiles.directory(url, enumerate: false) { _, info in
      guard info.st_dev == device, info.st_uid == getuid() else {
        throw CleanupFailure("The app cache owner or volume changed.")
      }
    }
    let path = String(url.path.dropFirst(home.path.count + 1))
    guard let match = Self.chromium(path) else { return }
    let storage = home.appending(path: match.storage)
    let names = try DirectoryIndex.children(of: storage, onDevice: device)
    let markers = names.contains { !$0.directory &&
      ["Local State", "Network Persistent State"].contains($0.url.lastPathComponent) }
    // A Chromium profile can inherit Local State from its user-data directory.
    let profileName = storage.lastPathComponent
    let inherited = profileName == "Default" || profileName == "Guest Profile"
      || profileName.wholeMatch(of: /Profile [0-9]+/) != nil
    guard markers || (inherited && (try? DirectoryIndex.children(of: storage.deletingLastPathComponent(),
      onDevice: device).contains { !$0.directory && $0.url.lastPathComponent == "Local State" }) == true) else {
      throw CleanupFailure("The Chromium cache format could not be verified.")
    }
    if url.lastPathComponent == "Cache" {
      let entries = try DirectoryIndex.children(of: url, onDevice: device)
      guard entries.contains(where: { $0.directory && $0.url.lastPathComponent == "Cache_Data" })
        || Set(entries.filter { !$0.directory }.map(\.url.lastPathComponent)).isSuperset(of: ["index", "data_0"])
      else { throw CleanupFailure("The Chromium cache format could not be verified.") }
    }
  }

  static func discover(home: URL, includeProtected: Bool, volumes: ScanVolumes, claimed: [ScanRoot],
                       apps: [ApplicationIdentity]) throws -> [ScanRoot] {
    let claimedPaths = claimed.map(\.url.path)
    var roots: [ScanRoot] = []
    func append(_ url: URL, rule: Self) throws {
      try Task.checkCancellation()
      let path = url.path
      guard !claimedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }),
        (try? rule.validate(url, home: home)) != nil else { return }
      var root = ScanRoot(group: .appCaches, title: rule.name + " · " + url.lastPathComponent,
                          url: url, profile: .appCache)
      root.evidence = .init(owner: rule.name, kind: .cache, rule: "app-cache." + rule.bundle,
                            inspectionOnly: false)
      root.application = apps.first { $0.bundleID == rule.bundle }
      roots.append(root)
    }
    func directories(_ url: URL) throws -> [URL] {
      try (DirectoryIndex.childrenIfReadable(of: url, onDevice: volumes.device(for: url)) ?? [])
        .filter { $0.directory && !$0.url.lastPathComponent.hasPrefix(".") }.map(\.url)
    }
    for rule in catalog {
      for path in rule.cachePaths where includeProtected || !path.hasPrefix("Library/Containers/") {
        try append(home.appending(path: path), rule: rule)
      }
      for path in rule.support {
        let base = home.appending(path: "Library/Application Support/" + path)
        let children = try directories(base)
        var folders = [base] + children
        for child in children where ["User Data", "DesktopProfile", "Partitions"].contains(child.lastPathComponent) {
          folders += try directories(child)
        }
        for folder in folders where at(folder.appending(path: "GPUCache"), home: home) == rule {
          for url in try directories(folder) where direct.contains(url.lastPathComponent) {
            try append(url, rule: rule)
          }
        }
      }
    }
    return roots
  }
}
