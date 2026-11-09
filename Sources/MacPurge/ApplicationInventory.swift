import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

struct ApplicationFootprint: Codable, Equatable, Identifiable, Sendable {
  struct Location: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let bytes: Int64?
    let complete: Bool
  }
  let id: String
  let name: String
  let path: String
  let measuredBytes: Int64
  let bundleBytes: Int64?
  let dataBytes: Int64?
  let complete: Bool
  let locations: [Location]
}

struct ApplicationDiscovery {
  let apps: [ApplicationIdentity]
  let roots: [ScanRoot]

  private static let aliases: [(String, String)] = [
    ("Library/Application Support/Code", "com.microsoft.VSCode"),
    ("Library/Application Support/Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Library/Application Support/Claude", "com.anthropic.claudefordesktop"),
    ("Library/Application Support/Codex", "com.openai.codex"),
    ("Library/Application Support/Google/Chrome", "com.google.Chrome"),
    ("Library/Caches/Google/Chrome", "com.google.Chrome"),
    (".vscode", "com.microsoft.VSCode"), (".cursor", "com.todesktop.230313mzl4w4u92"),
    ("Library/Developer/Xcode", "com.apple.dt.Xcode"),
    ("Library/Developer/CoreSimulator", "com.apple.dt.Xcode"),
  ]

  func owner(of url: URL, home: URL) -> ApplicationIdentity? {
    let path = url.path
    if let bundle = apps.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { return bundle }
    guard path.hasPrefix(home.path + "/") else { return nil }
    let relative = String(path.dropFirst(home.path.count + 1))
    for (alias, id) in Self.aliases where relative.caseInsensitiveCompare(alias) == .orderedSame
      || relative.lowercased().hasPrefix(alias.lowercased() + "/") {
      let matches = apps.filter { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
      return matches.count == 1 ? matches[0] : nil
    }
    let parts = relative.split(separator: "/").map(String.init)
    guard parts.count >= 3, parts[0] == "Library",
      ApplicationInventory.libraryFolders.contains(parts[1]) else { return nil }
    var key = parts[2].lowercased()
    for suffix in [".savedstate", ".shipit"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)) }
    if parts[1] == "Group Containers", let dot = key.firstIndex(of: ".") {
      key = String(key[key.index(after: dot)...])
    }
    let matches = apps.filter {
      $0.bundleID.lowercased() == key || $0.name.lowercased() == key
        || URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent.lowercased() == key
    }
    return matches.count == 1 ? matches[0] : nil
  }

  func attributing(_ root: ScanRoot, home: URL) -> ScanRoot {
    var root = root
    guard root.source == .directory || root.source == .file,
      let app = root.application ?? owner(of: root.url, home: home) else { return root }
    root.application = app
    if root.evidence == nil && root.group == .apps {
      root.evidence = .init(owner: app.name, kind: root.profile == .renderCache ? .cache : .applicationData,
        finding: .recognized, rule: "application.location", inspectionOnly: root.profile != .renderCache)
    }
    return root
  }
}

enum ApplicationInventory {
  struct Installed: Identifiable, Sendable {
    let identity: ApplicationIdentity
    let version: String?
    var id: String { identity.path }
  }

  static func metadata(at url: URL) -> [String: Any]? {
    guard let data = SmallMetadata.read(url.appending(path: "Contents/Info.plist")) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
  }

  // Logs are already measured by the quick scan's common root. Do not measure them twice.
  static let libraryFolders = ["Application Support", "Caches", "Containers", "Group Containers",
                               "WebKit", "HTTPStorages", "Saved Application State", "Application Scripts"]

  static func installed(home: URL, volumes: ScanVolumes, applicationFolders: [URL]? = nil) throws -> [Installed] {
    let folders = applicationFolders ?? [URL(fileURLWithPath: "/Applications"),
      URL(fileURLWithPath: "/System/Applications"), home.appending(path: "Applications")]
    var apps: [Installed] = []
    var seen = Set<String>()
    for folder in folders {
      let entries = try DeveloperDataInventory.children(folder, volumes: volumes)
      var bundles = entries.filter { $0.directory && $0.url.pathExtension.lowercased() == "app" }
      for entry in entries where entry.directory && entry.url.pathExtension.lowercased() != "app" {
        bundles += try DeveloperDataInventory.children(entry.url, volumes: volumes)
          .filter { $0.directory && $0.url.pathExtension.lowercased() == "app" }
      }
      for bundle in bundles {
        try Task.checkCancellation()
        guard seen.insert(bundle.url.path).inserted,
          let info = metadata(at: bundle.url),
          let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { continue }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
          ?? bundle.url.deletingPathExtension().lastPathComponent
        apps.append(.init(identity: .init(name: name, bundleID: id, path: bundle.url.path),
          version: (info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String))
      }
    }
    return apps
  }

  static func discover(home: URL, includeProtected: Bool, volumes: ScanVolumes,
                       applicationFolders: [URL]? = nil) throws -> ApplicationDiscovery {
    let apps = try installed(home: home, volumes: volumes, applicationFolders: applicationFolders).map(\.identity)
    var roots = apps.map { app in
      var root = ScanRoot(group: .apps, title: app.name, url: URL(fileURLWithPath: app.path), profile: .personal)
      root.evidence = .init(owner: app.name, kind: .application, finding: .installedApplication, rule: "application.bundle")
      root.application = app
      return root
    }
    let index = ApplicationDiscovery(apps: apps.sorted { $0.path < $1.path }, roots: [])
    for folder in libraryFolders where includeProtected || !["Containers", "Group Containers"].contains(folder) {
      let parent = home.appending(path: "Library/" + folder)
      for entry in try DeveloperDataInventory.children(parent, volumes: volumes) where entry.directory {
        try Task.checkCancellation()
        var candidates = [entry]
        // Recognize explicit vendor aliases such as Google/Chrome without claiming all vendor data.
        if entry.url.lastPathComponent == "Google" {
          candidates += try DeveloperDataInventory.children(entry.url, volumes: volumes).filter(\.directory)
        }
        for candidate in candidates {
          let owner = index.owner(of: candidate.url, home: home)
          let component = candidate.url.lastPathComponent
          let tail = folder == "Group Containers" ? component.split(separator: ".", maxSplits: 1).last.map(String.init) ?? component : component
          let bundleLike = tail.split(separator: ".").count >= 3
            && tail.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
          let vendor = tail.split(separator: ".").dropLast().joined(separator: ".").lowercased()
          let leftover = owner == nil && ["Containers", "Group Containers"].contains(folder) && bundleLike
            && !tail.lowercased().hasPrefix("com.apple.")
            && !apps.contains { $0.bundleID.lowercased().hasPrefix(vendor + ".") }
          guard owner != nil || leftover else { continue }
          var root = ScanRoot(group: .apps, title: owner?.name ?? component, url: candidate.url, profile: .personal)
          root.application = owner
          root.evidence = .init(owner: owner?.name ?? component, kind: .applicationData,
            finding: leftover ? .unmatchedApplication : .recognized, rule: "application.library")
          roots.append(root)
        }
      }
    }
    return ApplicationDiscovery(apps: index.apps, roots: roots)
  }

  /// Compute allocated unions from saved measurements; never reads the filesystem.
  static func footprints(roots: [ScanRoot], results: [String: RootSize]) throws -> [ApplicationFootprint] {
    let grouped = Dictionary(grouping: roots.filter { $0.application != nil
      && ($0.source == .directory || $0.source == .file) }, by: { $0.application!.path })
    var output: [ApplicationFootprint] = []
    for (_, members) in grouped {
      try Task.checkCancellation()
      let app = members[0].application!
      var total = GroupSize(), bundle = GroupSize(), data = GroupSize()
      var complete = true
      var locations: [ApplicationFootprint.Location] = []
      for root in members {
        let size = results[root.id]
        let measured = size?.measured == true
        if size?.state != .complete { complete = false }
        locations.append(.init(id: ScanReport.itemID(root), path: root.url.path,
          bytes: measured ? size?.bytes : nil, complete: size?.state == .complete))
        guard let size else { continue }
        try total.include(size, for: root)
        if root.url.path == app.path { try bundle.include(size, for: root) }
        else { try data.include(size, for: root) }
      }
      locations.sort { $0.bytes == $1.bytes ? $0.path < $1.path : ($0.bytes ?? -1) > ($1.bytes ?? -1) }
      output.append(.init(id: app.path, name: app.name, path: app.path, measuredBytes: total.bytes ?? 0,
        bundleBytes: bundle.bytes, dataBytes: data.bytes, complete: complete, locations: locations))
    }
    return output.sorted { $0.measuredBytes == $1.measuredBytes ? $0.id < $1.id : $0.measuredBytes > $1.measuredBytes }
  }
}
