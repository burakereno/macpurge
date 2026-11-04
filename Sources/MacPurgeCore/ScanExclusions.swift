import Foundation

/// An immutable policy inherited by discovery and measurement tasks in one scan.
package struct ScanExclusions: Sendable {
  package static let preference = "scanExcludedPaths"
  @TaskLocal package static var current = ScanExclusions(paths: [])
  package let paths: [String]

  package init(paths: [String]) {
    self.paths = Array(Set(paths.filter { $0.hasPrefix("/") }.map {
      Self.normalizedPath($0)
    })).sorted()
  }

  // URL.standardizedFileURL can rewrite /private/tmp to /tmp on macOS.
  // Keep the scan's physical spelling while normalizing path components.
  private static func normalizedPath(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." { if !parts.isEmpty { parts.removeLast() } }
      else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
  }

  package static func saved(in defaults: UserDefaults = .standard) -> Self {
    Self(paths: defaults.stringArray(forKey: preference) ?? [])
  }

  package func contains(_ url: URL) -> Bool {
    paths.contains { Self.contains(url.path, under: $0) }
  }

  package func overlaps(_ url: URL) -> Bool {
    contains(url) || paths.contains { Self.contains($0, under: url.path) }
  }

  private static func contains(_ path: String, under parent: String) -> Bool {
    path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/")
  }

  package func applying(to root: ScanRoot) -> ScanRoot? {
    guard !contains(root.url) else { return nil }
    // Tool-reported totals cannot subtract individual subfolders reliably.
    if root.source != .directory {
      // Snapshot rows describe volume metadata, not a traversable folder tree.
      return root.group == .snapshots || !overlaps(root.url) ? root : nil
    }
    var root = root
    root.containsScanExclusions = overlaps(root.url)
    let prefix = root.url.path == "/" ? "/" : root.url.path + "/"
    for path in paths where path.hasPrefix(prefix) {
      root.excludedDirectories.insert(String(path.dropFirst(prefix.count)))
    }
    return root
  }
}
