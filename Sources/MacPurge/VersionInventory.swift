import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

enum VersionInventory {
  static func normalized(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." { if !parts.isEmpty { parts.removeLast() } }
      else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
  }
  struct Version: Comparable {
    let components: [Int]
    init?(_ text: String) {
      let bare = text.hasPrefix("v") ? String(text.dropFirst()) : text
      let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
      guard (1...5).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
        parts.allSatisfy({ Int($0) != nil }) else { return nil }
      components = parts.compactMap { Int($0) }
    }
    static func < (a: Self, b: Self) -> Bool {
      for i in 0..<max(a.components.count, b.components.count) {
        let x = a.components.indices.contains(i) ? a.components[i] : 0
        let y = b.components.indices.contains(i) ? b.components[i] : 0
        if x != y { return x < y }
      }
      return false
    }
    static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }
  }

  static func text(_ url: URL) -> String? {
    SmallMetadata.read(url, limit: 32768).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private static func nvmDefault(_ home: URL) -> String? {
    var name = "default", visited = Set<String>()
    for _ in 0..<8 {
      guard visited.insert(name).inserted, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
        let target = text(home.appending(path: ".nvm/alias/" + name)), !target.contains("\n") else { return nil }
      let value = target.hasPrefix("v") ? String(target.dropFirst()) : target
      if Version(value) != nil { return value }
      name = target
    }
    return nil
  }

  static func discover(home: URL, volumes: ScanVolumes, brewPrefixes: [URL]? = nil) throws -> [ScanRoot] {
    var roots: [ScanRoot] = []
    let languages: [(String, String, String?, Int, String)] = [
      ("Node.js", ".nvm/versions/node", nvmDefault(home), 1, "nvm ls"),
      ("Python", ".pyenv/versions", text(home.appending(path: ".pyenv/version")), 2, "pyenv versions"),
      ("Ruby", ".rbenv/versions", text(home.appending(path: ".rbenv/version")), 2, "rbenv versions"),
    ]
    for (owner, path, current, familyLength, command) in languages {
      let entries = try DeveloperDataInventory.children(home.appending(path: path), volumes: volumes).filter(\.directory)
      let versions = entries.compactMap { entry in Version(entry.url.lastPathComponent).map { (entry, $0) } }
      let known = current != nil && versions.contains { pair in
        let bare = pair.0.url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        return bare == current || bare.hasPrefix((current ?? "") + ".")
      }
      for (entry, version) in versions {
        try Task.checkCancellation()
        let bare = entry.url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let isDefault = known && (bare == current || bare.hasPrefix((current ?? "") + "."))
        let newer = versions.filter { Array($0.1.components.prefix(familyLength)) == Array(version.components.prefix(familyLength)) && $0.1 > version }
          .max { $0.1 < $1.1 }
        var row = ScanRoot(group: .tools, title: owner + " " + entry.url.lastPathComponent, url: entry.url, profile: .personal)
        row.evidence = .init(owner: owner, kind: .toolVersion,
          finding: isDefault ? .currentVersion : known && newer != nil ? .olderVersion : known ? .recognized : .unknownVersion,
          rule: "version.language")
        row.evidence?.note = [current.map { "Default: " + $0 }, newer.map { "Newer in this release line: " + $0.0.url.lastPathComponent }].compactMap { $0 }.joined(separator: " · ")
        row.evidence?.management = command
        roots.append(row)
      }
    }
    let rustSettings = text(home.appending(path: ".rustup/settings.toml"))
    let rustDefault = rustSettings?.split(separator: "\n").compactMap { line -> String? in
      let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      return pair.count == 2 && pair[0] == "default_toolchain" ? pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : nil
    }.first
    for entry in try DeveloperDataInventory.children(home.appending(path: ".rustup/toolchains"), volumes: volumes) where entry.directory {
      var row = ScanRoot(group: .tools, title: "Rust · " + entry.url.lastPathComponent, url: entry.url, profile: .personal)
      row.evidence = .init(owner: "Rust", kind: .toolVersion,
        finding: rustDefault == entry.url.lastPathComponent ? .currentVersion : .unknownVersion, rule: "version.rustup")
      row.evidence?.management = "rustup toolchain list"
      roots.append(row)
    }
    for prefix in brewPrefixes ?? [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")] {
      for package in try DeveloperDataInventory.children(prefix.appending(path: "Cellar"), volumes: volumes) where package.directory {
        let installed = try DeveloperDataInventory.children(package.url, volumes: volumes).filter(\.directory)
        let linkedURL = prefix.appending(path: "opt/" + package.url.lastPathComponent)
        let linked = !ScanExclusions.current.overlaps(linkedURL) ? try? FileManager.default.destinationOfSymbolicLink(atPath: linkedURL.path) : nil
        let target = linked.map { link in
          URL(fileURLWithPath: normalized(link.hasPrefix("/") ? link : linkedURL.deletingLastPathComponent().path + "/" + link))
        }
        let current = target.flatMap { url in installed.contains(where: { $0.url.path == url.path }) ? url.lastPathComponent : nil }
        for entry in installed {
          var row = ScanRoot(group: .tools, title: "Homebrew · " + package.url.lastPathComponent + " " + entry.url.lastPathComponent,
                            url: entry.url, profile: .personal)
          let older = current.flatMap(Version.init).flatMap { active in Version(entry.url.lastPathComponent).map { $0 < active } } == true
          row.evidence = .init(owner: "Homebrew", kind: .toolVersion,
            finding: current == nil ? .unknownVersion : current == entry.url.lastPathComponent ? .currentVersion : older ? .olderVersion : .recognized,
            rule: "version.homebrew")
          row.evidence?.note = current.map { "Linked version: " + $0 }
          row.evidence?.management = "brew cleanup --dry-run"
          roots.append(row)
        }
      }
    }
    return roots
  }
}
