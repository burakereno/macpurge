import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// Split broad inventory locations around more specific rows. A browser's model,
/// for example, belongs to AI, while its sibling profiles belong to the app.
enum CategoryLocations {
  static func discover(home: URL, known: [ScanRoot], includeProtected: Bool) throws -> [ScanRoot] {
    let skippedSupport = [
      "AddressBook", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs", "CloudStorage",
      "FileProvider", "MobileSync", "Knowledge", "FaceTime", "SyncServices", "MacPurge",
      "com.apple.TCC", "com.apple.sharedfilelist",
    ]
    let support = home.appending(path: "Library/Application Support")
    var excluded = known.map(\.url) + skippedSupport.map { support.appending(path: $0) }
    // Cloud/file-provider trees and another app's protected state are not cache candidates.
    excluded += ["Containers", "Group Containers", "CloudStorage", "Mobile Documents"].map {
      home.appending(path: "Library/" + $0)
    }
    let caches = home.appending(path: "Library/Caches")
    let systemSupport = URL(fileURLWithPath: "/Library/Application Support")
    var roots: [ScanRoot] = []
    func add(
      _ group: ScanGroup, _ location: URL, _ profile: StorageProfile,
      exclusions: [URL]? = nil, allow: (String) -> Bool = { _ in true }
    ) throws {
      roots += try unclaimed(
        in: location, group: group, profile: profile,
        excluding: exclusions ?? excluded, allow: allow)
    }
    let nonApple: (String) -> Bool = {
      !$0.hasPrefix(".") && !$0.hasPrefix("com.apple.") && !$0.hasPrefix("group.com.apple.")
    }
    try add(.apps, support, .personal, allow: nonApple)
    try add(.apps, caches, .unknown, allow: nonApple)
    try add(.system, systemSupport, .systemManaged, allow: nonApple)
    if includeProtected {
      let containers = ["Containers", "Group Containers"].map {
        home.appending(path: "Library/" + $0)
      }
      for location in containers {
        try add(
          .apps, location, .personal, exclusions: excluded.filter { $0.path != location.path },
          allow: nonApple)
      }
    }
    for path in [
      ".gradle", ".cargo", ".rustup", ".bun", ".swiftpm", ".dotnet", ".expo", ".gem",
      ".supabase", ".vscode", ".cursor", ".local/bin",
    ] {
      try add(.tools, home.appending(path: path), .personal)
    }
    for location in [
      home.appending(path: ".cache"), home.appending(path: ".local/share"),
      URL(fileURLWithPath: "/opt"), URL(fileURLWithPath: "/usr/local"),
    ] {
      try add(.other, location, .unknown)
    }
    return roots
  }

  static func unclaimed(
    in location: URL, group: ScanGroup, profile: StorageProfile,
    excluding known: [URL], allow: (String) -> Bool = { _ in true }
  ) throws -> [ScanRoot] {
    // All discovery paths descend from explicit roots. File-system standardization
    // can rewrite /private/tmp as /tmp only for paths that already exist.
    // Keep descriptor paths and ownership comparisons in the same spelling.
    let reserved = Set(known.map(\.path))
    let root = location.path
    guard !reserved.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) else { return [] }
    var origin = stat()
    let originDevice = lstat(root, &origin) == 0 ? origin.st_dev : nil
    var rows: [ScanRoot] = []
    func visit(_ directory: URL) throws {
      try Task.checkCancellation()
      let entries: [DirectoryIndex.Entry]
      do { entries = try DirectoryIndex.children(of: directory) } catch is CancellationError {
        throw CancellationError()
      } catch let error as DirectoryIndex.Problem where error.code == ENOENT { return } catch {
        rows.append(
          .init(
            group: group, title: directory.lastPathComponent, url: directory,
            source: .status("Konum listelenemedi")))
        return
      }
      for entry in entries {
        try Task.checkCancellation()
        let path = entry.url.path
        let name = entry.url.lastPathComponent
        guard entry.device == originDevice, directory.path != root || allow(name),
          !reserved.contains(path)
        else { continue }
        if reserved.contains(where: { $0.hasPrefix(path + "/") }) {
          if entry.directory { try visit(entry.url) }
        } else if entry.directory || (directory.path != root && !name.hasPrefix(".")) {
          let label = String(path.dropFirst(root.count + 1))
          rows.append(
            .init(
              group: group, title: label, url: entry.url, profile: profile,
              source: entry.directory ? .directory : .file))
        }
      }
    }
    try visit(location)
    return rows
  }
}
