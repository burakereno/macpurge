import Darwin
import Foundation
import SQLite3

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// Read-only comparison of pnpm's stored files with the lockfiles we could inspect.
struct PnpmStoreAudit: Sendable {
  struct Version: Identifiable, Sendable {
    let id: String
    let unmatchedBytes: Int64?
  }

  let versions: [Version]
  let wantedLocks: Int
  let installedLocks: Int
  let projectScopes: Int
  let registeredProjects: Int
  let incomplete: Bool
  var unmatchedBytes: Int64 {
    versions.compactMap(\.unmatchedBytes).reduce(0, +)
  }

  private enum Invalid: Error { case format }
  private enum LockKind { case wanted, installed }
  private struct References {
    var packages = Set<String>()
    var digests = Set<String>()
  }

  static func supports(_ url: URL, home: URL) -> Bool {
    ["Library/pnpm/store", ".local/share/pnpm/store", ".pnpm-store"].contains {
      url.path == home.appending(path: $0).path
    }
  }

  @concurrent static func read(store: URL, projects: [URL], exclusions: ScanExclusions) async throws -> Self {
    try ScanExclusions.$current.withValue(exclusions) {
      guard !exclusions.contains(store) else { throw Invalid.format }
      let versionFolders = try DirectoryIndex.children(of: store).filter {
        $0.directory && ["v10", "v11"].contains($0.url.lastPathComponent)
      }
      guard !versionFolders.isEmpty else { throw Invalid.format }
      var incomplete = exclusions.overlaps(store)
      var lockfiles: [URL: LockKind] = [:]
      var registered = Set<URL>()

      func addLock(_ url: URL, kind: LockKind) {
        var info = stat()
        if exclusions.contains(url) {
          incomplete = true
        } else if lstat(url.path, &info) == 0 {
          lockfiles[url] = kind
        } else if errno != ENOENT && errno != ENOTDIR {
          incomplete = true
        }
      }

      for folder in versionFolders {
        let registry = folder.url.appending(path: "projects")
        guard !exclusions.contains(registry) else { continue }
        do {
          try TrashFiles.directory(registry, enumerate: false) { _, _ in }
          for link in try FileManager.default.contentsOfDirectory(
            at: registry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
          {
            try Task.checkCancellation()
            guard !exclusions.contains(link) else { continue }
            var info = stat()
            guard lstat(link.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { continue }
            guard let resolved = realpath(link.path, nil) else {
              if errno != ENOENT { incomplete = true }
              continue
            }
            let project = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
            free(resolved)
            if exclusions.contains(project) || exclusions.contains(link.resolvingSymlinksInPath()) {
              incomplete = true
            } else if stat(project.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
              registered.insert(project)
            } else {
              incomplete = true
            }
          }
        } catch let error as POSIXError where error.code == .ENOENT {
          // An empty registry is valid.
        } catch is CancellationError { throw CancellationError() }
        catch { incomplete = true }
      }
      for project in registered {
        addLock(project.appending(path: "pnpm-lock.yaml"), kind: .wanted)
        addLock(project.appending(path: "node_modules/.pnpm/lock.yaml"), kind: .installed)
      }

      // Stay inside the selected project roots, skipping installed dependencies and build outputs.
      let skip = StorageMeter.outputFolders.union(["vendor", "build", "dist", "target", "Pods", "venv"])
      var visited = Set<String>()
      var pending: [(URL, dev_t?)] = projects.map { ($0, nil) }
      while let (dir, device) = pending.popLast() {
        try Task.checkCancellation()
        guard !exclusions.contains(dir), visited.insert(dir.path).inserted else { continue }
        guard visited.count <= 30_000 else { incomplete = true; break }
        do {
          let children = try DirectoryIndex.children(of: dir, onDevice: device)
          for entry in children {
            let name = entry.url.lastPathComponent
            if entry.directory && !name.hasPrefix(".") && !skip.contains(name)
              && !["app", "bundle", "framework", "xcodeproj", "xcworkspace"].contains(entry.url.pathExtension)
            {
              pending.append((entry.url, entry.device))
            } else if !entry.directory && name == "pnpm-lock.yaml" {
              addLock(entry.url, kind: .wanted)
              addLock(dir.appending(path: "node_modules/.pnpm/lock.yaml"), kind: .installed)
            }
          }
        } catch is CancellationError { throw CancellationError() }
        catch { incomplete = true }
      }

      var references = References()
      var wanted = 0
      var installed = 0
      for (url, kind) in lockfiles {
        try Task.checkCancellation()
        guard let data = SmallMetadata.read(url, limit: 32 * 1024 * 1024),
          let value = Self.lockReferences(data)
        else { incomplete = true; continue }
        references.packages.formUnion(value.packages)
        references.digests.formUnion(value.digests)
        if kind == .wanted { wanted += 1 } else { installed += 1 }
      }

      var versions: [Version] = []
      for folder in versionFolders {
        let version = folder.url.lastPathComponent
        do {
          // With no readable lockfiles we have no basis for a comparison.
          guard wanted + installed > 0 else { throw Invalid.format }
          let bytes = try unmatched(in: folder, version: version, references: references)
          versions.append(.init(id: version, unmatchedBytes: bytes))
        } catch is CancellationError { throw CancellationError() }
        catch {
          incomplete = true
          versions.append(.init(id: version, unmatchedBytes: nil))
        }
      }
      return Self(
        versions: versions.sorted {
          let lhs = $0.unmatchedBytes ?? -1
          let rhs = $1.unmatchedBytes ?? -1
          return lhs == rhs ? $0.id < $1.id : lhs > rhs
        },
        wantedLocks: wanted, installedLocks: installed, projectScopes: projects.count,
        registeredProjects: registered.count, incomplete: incomplete)
    }
  }

  /// Read the package identities and integrity fields in pnpm's generated YAML block.
  /// Unrecognized package layouts count as unreadable, never as empty lockfiles.
  private static func lockReferences(_ data: Data) -> References? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var foundVersion = false
    var inPackages = false
    var sawPackages = false
    var packageIndent: Int?
    var result = References()
    for raw in text.split(whereSeparator: \.isNewline) {
      let indent = raw.prefix(while: { $0 == " " }).count
      let line = raw.dropFirst(indent).trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if indent == 0 {
        if raw.first == "\t" { return nil }
        if inPackages && packageIndent == nil { return nil }
        inPackages = false
        guard let separator = line.firstIndex(of: ":") else { continue }
        let key = scalar(String(line[..<separator]))
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if key == "lockfileVersion" {
          let version = scalar(value)
          guard let version, let number = Double(version), number >= 5, number < 10 else { return nil }
          foundVersion = true
        }
        if key == "packages" {
          guard !sawPackages, value.isEmpty || value == "{}" else { return nil }
          inPackages = value.isEmpty
          sawPackages = true
        }
        continue
      }
      guard inPackages else { continue }
      if packageIndent == nil { packageIndent = indent }
      if indent == packageIndent {
        let suffix = line.hasSuffix(": {}") ? ": {}" : ":"
        guard line.hasSuffix(suffix), let id = scalar(String(line.dropLast(suffix.count))), !id.isEmpty,
          !id.hasPrefix("*"), !id.hasPrefix("&"), id != "<<"
        else { return nil }
        result.packages.insert(packageID(id))
      } else if indent < (packageIndent ?? 0) {
        return nil
      }
      guard line.contains("integrity:") else { continue }
      for match in integrityPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
        if let range = Range(match.range(at: 1), in: line), let hash = hexIntegrity(String(line[range])) {
          result.digests.insert(hash)
          result.digests.insert(String(hash.prefix(64)))
        }
      }
    }
    return foundVersion && (!inPackages || packageIndent != nil) ? result : nil
  }

  private static let integrityPattern = try! NSRegularExpression(
    pattern: #"\bintegrity:\s*['"]?(sha(?:1|256|384|512)-[A-Za-z0-9+/]+=*)"#)
  private static let legacyPackagePattern = try! NSRegularExpression(
    pattern: #"^(@[^/]+/[^/@]+|[^/@]+)/(\d[^/_]*)(?:_.*)?$"#)

  private static func scalar(_ value: String) -> String? {
    if value.hasPrefix("'") {
      guard value.count >= 2, value.hasSuffix("'") else { return nil }
      return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    if value.hasPrefix("\"") {
      return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
    }
    return value
  }

  private static func packageID(_ value: String) -> String {
    let value = String((value.hasPrefix("/") ? value.dropFirst() : value[...]).prefix { $0 != "(" })
    guard let match = legacyPackagePattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      let name = Range(match.range(at: 1), in: value), let version = Range(match.range(at: 2), in: value)
    else { return value }
    return value[name] + "@" + value[version]
  }

  private static func hexIntegrity(_ value: String) -> String? {
    for token in value.split(separator: " ") {
      let parts = token.split(separator: "-", maxSplits: 1)
      guard parts.count == 2, ["sha1", "sha256", "sha384", "sha512"].contains(parts[0]),
        let bytes = Data(base64Encoded: String(parts[1])), [20, 32, 48, 64].contains(bytes.count)
      else { continue }
      let digits = Array("0123456789abcdef".utf8)
      return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
    return nil
  }

  private static func isDigest(_ value: String) -> Bool {
    [40, 64, 96, 128].contains(value.utf8.count) &&
      value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func unmatched(in folder: DirectoryIndex.Entry, version: String, references: References) throws -> Int64 {
    var indexed = Set<String>()
    var retained = Set<String>()
    func add(_ package: [String: Any], id: String, hash: String?) throws {
      guard let files = package["files"] as? [String: Any] else { throw Invalid.format }
      var keep = references.packages.contains(id) || hash.map(references.digests.contains) == true
      // Keep content whose package identity or source digest could not be interpreted.
      if id.range(of: #"^(?:@[^/]+/)?[^@/]+@\d[^/]*$"#, options: .regularExpression) == nil
        || hash == nil { keep = true }

      func addFiles(_ files: [String: Any]) throws {
        for raw in files.values {
          guard let file = raw as? [String: Any], let mode = file["mode"] as? Int,
            let digest = (file["digest"] as? String) ?? (file["integrity"] as? String).flatMap(hexIntegrity),
            isDigest(digest)
          else { throw Invalid.format }
          let key = mode & 0o111 == 0 ? digest : digest + "-exec"
          indexed.insert(key)
          if keep { retained.insert(key) }
        }
      }

      try addFiles(files)
      if let sideEffects = package["sideEffects"] as? [String: Any] {
        for raw in sideEffects.values {
          guard let patch = raw as? [String: Any] else { throw Invalid.format }
          if let added = patch["added"] as? [String: Any] { try addFiles(added) }
          else if patch.keys.allSatisfy({ $0 != "deleted" }) { try addFiles(patch) }
        }
      }
    }

    if version == "v10" {
      try walkBuckets(folder.url.appending(path: "index"), device: folder.device) { bucket, file in
        guard file.lastPathComponent.hasSuffix(".json"),
          let data = SmallMetadata.read(file, limit: 32 * 1024 * 1024),
          let package = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Invalid.format }
        let name = package["name"] as? String
        let version = package["version"] as? String
        let id = name.flatMap { name in version.map { name + "@" + $0 } } ?? ""
        let hash = bucket + String(file.lastPathComponent.prefix(while: { $0 != "-" }))
        try add(package, id: id, hash: isDigest(hash) ? hash : nil)
      }
    } else {
      try readDatabase(at: folder.url.appending(path: "index.db")) { key, data in
        let parts = key.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { throw Invalid.format }
        var reader = PnpmIndexMessagePack(data)
        guard let package = try reader.readRoot() as? [String: Any] else { throw Invalid.format }
        let manifest = package["manifest"] as? [String: Any]
        let name = manifest?["name"] as? String
        let version = manifest?["version"] as? String
        let id = name.flatMap { name in version.map { name + "@" + $0 } } ?? packageID(String(parts[1]))
        try add(package, id: id, hash: hexIntegrity(String(parts[0])))
      }
    }
    var bytes: Int64 = 0
    try walkBuckets(folder.url.appending(path: "files"), device: folder.device) { bucket, file in
      let key = bucket + file.lastPathComponent
      guard indexed.contains(key), !retained.contains(key) else { return }
      var info = stat()
      guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_dev == folder.device
      else { throw Invalid.format }
      // Do not count files with extra hard links. APFS clone sharing can still affect real disk gains.
      if info.st_nlink == 1 { bytes += Int64(info.st_blocks) * 512 }
    }
    return bytes
  }

  private static func walkBuckets(_ root: URL, device: dev_t, visit: (String, URL) throws -> Void) throws {
    guard !ScanExclusions.current.overlaps(root) else { throw Invalid.format }
    for bucket in try DirectoryIndex.children(of: root, onDevice: device) where bucket.directory {
      let name = bucket.url.lastPathComponent
      guard name.utf8.count == 2, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { continue }
      for entry in try DirectoryIndex.children(of: bucket.url, onDevice: device) where !entry.directory {
        try visit(name, entry.url)
      }
    }
  }

  private static func readDatabase(at url: URL, visit: (String, Data) throws -> Void) throws {
    func stableFile() throws -> stat {
      var info = stat()
      guard !ScanExclusions.current.contains(url), lstat(url.path, &info) == 0,
        info.st_mode & S_IFMT == S_IFREG else { throw Invalid.format }
      for suffix in ["-wal", "-journal"] {
        var journal = stat()
        guard lstat(url.path + suffix, &journal) != 0, errno == ENOENT else { throw Invalid.format }
      }
      return info
    }

    let before = try stableFile()
    var db: OpaquePointer?
    let status = sqlite3_open_v2(url.absoluteString + "?mode=ro&immutable=1", &db,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW, nil)
    defer { sqlite3_close(db) }
    guard status == SQLITE_OK, let db else { throw Invalid.format }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT key, data FROM package_index", -1, &statement, nil) == SQLITE_OK,
      let statement else { throw Invalid.format }
    defer { sqlite3_finalize(statement) }
    while true {
      try Task.checkCancellation()
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      let count = Int(sqlite3_column_bytes(statement, 1))
      guard step == SQLITE_ROW, let key = sqlite3_column_text(statement, 0),
        let data = sqlite3_column_blob(statement, 1), count > 0, count <= 32 * 1024 * 1024
      else { throw Invalid.format }
      try visit(String(cString: key), Data(bytes: data, count: count))
    }
    let after = try stableFile()
    guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw Invalid.format }
  }
}
