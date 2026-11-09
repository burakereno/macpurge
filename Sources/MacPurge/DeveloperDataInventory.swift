import Darwin
import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

/// Bounded metadata reads during discovery; no databases or user files are modified.
enum DeveloperDataInventory {
  static func children(_ url: URL, volumes: ScanVolumes) throws -> [DirectoryIndex.Entry] {
    do { return try DirectoryIndex.children(of: url, onDevice: volumes.device(for: url)) }
    catch is DirectoryIndex.Problem { return [] }
  }

  static func projectFinding(_ raw: String?, home: URL) -> (InventoryEvidence.Finding, String?) {
    guard let raw, let url = URL(string: raw), url.scheme != nil else { return (.unknownProject, nil) }
    guard url.isFileURL else { return (.remoteProject, nil) }
    guard url.host == nil || url.host == "" || url.host == "localhost",
      url.path.hasPrefix(home.path + "/"),
      !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      !ScanExclusions.current.overlaps(url) else { return (.unknownProject, nil) }
    let fd = open(url.path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return (errno == ENOENT ? .missingProject : .unknownProject, url.path) }
    defer { close(fd) }
    var info = stat(), homeInfo = stat()
    guard fstat(fd, &info) == 0, lstat(home.path, &homeInfo) == 0,
      info.st_dev == homeInfo.st_dev else { return (.unknownProject, nil) }
    return (.projectPresent, url.path)
  }

  static func discover(home: URL, volumes: ScanVolumes) throws -> [ScanRoot] {
    var roots: [ScanRoot] = []
    for (name, support, extensions) in [
      ("Cursor", "Cursor", ".cursor/extensions"),
      ("VS Code", "Code", ".vscode/extensions"),
      ("Windsurf", "Windsurf", ".windsurf/extensions"),
    ] {
      let workspaces = home.appending(path: "Library/Application Support/\(support)/User/workspaceStorage")
      for entry in try children(workspaces, volumes: volumes) where entry.directory {
        try Task.checkCancellation()
        let data = SmallMetadata.read(entry.url.appending(path: "workspace.json"))
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let (finding, project) = projectFinding(json?["folder"] as? String ?? json?["workspace"] as? String, home: home)
        var root = ScanRoot(group: .tools, title: name + " · " + (project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? entry.url.lastPathComponent),
                            url: entry.url, profile: .personal)
        root.evidence = .init(owner: name, kind: .workspace, finding: finding, rule: "editor.workspace", projectPath: project)
        roots.append(root)
      }
      let folder = home.appending(path: extensions)
      let data = SmallMetadata.read(folder.appending(path: "extensions.json"), limit: 8 * 1024 * 1024)
      let registry = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
      var registered = Set<String>()
      var valid = registry != nil
      for record in registry ?? [] {
        let location = record["location"] as? [String: Any]
        if let relative = record["relativeLocation"] as? String,
           !relative.contains("/"), relative != ".", relative != ".." {
          registered.insert(relative)
        } else if let path = location?["path"] as? String,
                  URL(fileURLWithPath: path).deletingLastPathComponent().path == folder.path {
          registered.insert(URL(fileURLWithPath: path).lastPathComponent)
        } else { valid = false }
      }
      for entry in try children(folder, volumes: volumes) where entry.directory && !entry.url.lastPathComponent.hasPrefix(".") {
        try Task.checkCancellation()
        var root = ScanRoot(group: .tools, title: name + " · " + entry.url.lastPathComponent, url: entry.url, profile: .personal)
        root.evidence = .init(owner: name, kind: .extensionFiles,
          finding: !valid ? .unknownRegistry : registered.contains(entry.url.lastPathComponent) ? .registeredExtension : .unregisteredExtension,
          rule: "editor.extension-registry")
        roots.append(root)
      }
    }
    roots += try aiData(home: home, volumes: volumes)
    return roots
  }

  private static func aiData(home: URL, volumes: ScanVolumes) throws -> [ScanRoot] {
    var roots: [ScanRoot] = []
    let rules: [(String, String, InventoryEvidence.Kind)] = [
      ("Claude Code", ".claude/debug", .logs), ("Claude Code", ".claude/cache", .cache),
      ("Claude Code", ".claude/file-history", .checkpoint),
      ("Claude Code", ".claude/shell-snapshots", .checkpoint),
      ("Claude Code", ".claude/settings.json", .settings),
      ("Claude Code", ".claude/settings.local.json", .settings),
      ("Claude Code", ".claude/.credentials.json", .settings),
      ("Claude Code", ".claude/history.jsonl", .history),
      ("Codex", ".codex/log", .logs), ("Codex", ".codex/logs", .logs),
      ("Codex", ".codex/cache", .cache), ("Codex", ".codex/sessions", .history),
      ("Codex", ".codex/archived_sessions", .history),
      ("Codex", ".codex/history.jsonl", .history), ("Codex", ".codex/sqlite", .history),
      ("Codex", ".codex/config.toml", .settings), ("Codex", ".codex/auth.json", .settings),
      ("Codex", ".codex/shell_snapshots", .checkpoint),
    ]
    // Discover each explicitly named leaf through its physical parent. Neither credentials
    // nor conversations are opened; their type comes from the tool's known location.
    var byParent: [URL: [DirectoryIndex.Entry]] = [:]
    for (owner, path, kind) in rules {
      try Task.checkCancellation()
      let url = home.appending(path: path)
      let parent = url.deletingLastPathComponent()
      if byParent[parent] == nil { byParent[parent] = try children(parent, volumes: volumes) }
      guard let entry = byParent[parent]?.first(where: { $0.url.path == url.path }) else { continue }
      var root = ScanRoot(group: .models, title: owner + " · " + url.lastPathComponent,
        url: url, profile: .personal, source: entry.directory ? .directory : .file)
      root.evidence = .init(owner: owner, kind: kind, rule: "agent." + kind.rawValue)
      roots.append(root)
    }
    let projects = home.appending(path: ".claude/projects")
    for entry in try children(projects, volumes: volumes) where entry.directory {
      try Task.checkCancellation()
      let data = SmallMetadata.read(entry.url.appending(path: "sessions-index.json"))
      let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let entries = json?["entries"] as? [[String: Any]] ?? []
      let paths = Set(entries.compactMap { $0["projectPath"] as? String })
      let path = json?["originalPath"] as? String ?? (paths.count == 1 ? paths.first : nil)
      let uri = path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).absoluteString : nil }
      let (finding, project) = projectFinding(uri, home: home)
      var root = ScanRoot(group: .models, title: "Claude Code · " + entry.url.lastPathComponent,
                          url: entry.url, profile: .personal)
      root.evidence = .init(owner: "Claude Code", kind: .history, finding: finding,
                           rule: "agent.claude-project", projectPath: project)
      roots.append(root)
    }
    for (owner, support) in [("Claude", "Claude"), ("Codex", "Codex")] {
      let base = home.appending(path: "Library/Application Support/" + support)
      for entry in try children(base, volumes: volumes) {
        let name = entry.url.lastPathComponent
        let kind: InventoryEvidence.Kind?
        switch name.lowercased() {
        case "cache", "code cache", "gpucache", "dawngraphitecache", "dawnwebgpucache": kind = .cache
        case "logs": kind = .logs
        case "updates", "pending": kind = .update
        default: kind = name.hasSuffix(".db") || name.hasSuffix(".sqlite") ? .history : nil
        }
        guard let kind else { continue }
        var root = ScanRoot(group: .models, title: owner + " · " + name, url: entry.url,
          profile: .personal, source: entry.directory ? .directory : .file)
        root.evidence = .init(owner: owner, kind: kind, rule: "agent.app-" + kind.rawValue)
        roots.append(root)
      }
    }
    return roots
  }
}

enum InventoryPartition {
  /// New typed children replace duplicate broad rows and are subtracted from ancestors.
  static func merging(_ base: [ScanRoot], details: [ScanRoot]) -> [ScanRoot] {
    var seen = Set<String>()
    let originals = Dictionary(base.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
    let enriched = details.map { detail -> ScanRoot in
      if var original = originals[detail.url.path], original.profile == .renderCache {
        original.evidence = detail.evidence
        original.evidence?.inspectionOnly = false
        return original
      }
      return detail
    }
    var roots = (enriched + base).filter { root in
      let key = root.source == .directory || root.source == .file ? root.url.path : root.id
      return seen.insert(key).inserted
    }
    let physical = roots.filter { $0.source == .directory || $0.source == .file }.map(\.url.path)
    for i in roots.indices where roots[i].source == .directory {
      let prefix = roots[i].url.path + "/"
      roots[i].excludedDirectories.formUnion(physical.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
    return roots
  }
}
