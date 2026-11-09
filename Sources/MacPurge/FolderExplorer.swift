import Darwin
import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

enum ExplorerMode: String, CaseIterable, Sendable {
  case folders = "Folder contents", largest = "Largest files"
}

enum ExplorerKind: String, CaseIterable, Sendable {
  case folder = "Folders", video = "Video", audio = "Audio", image = "Images"
  case archive = "Archives and installers", document = "Documents", development = "Development files", other = "Other files"

  static func file(_ name: String) -> Self {
    let ext = (name as NSString).pathExtension.lowercased()
    if ["mov", "mp4", "mkv", "avi", "m4v", "webm"].contains(ext) { return .video }
    if ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg"].contains(ext) { return .audio }
    if ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp", "raw", "svg"].contains(ext) { return .image }
    if ["zip", "gz", "xz", "tar", "7z", "rar", "dmg", "pkg", "xip", "iso"].contains(ext) { return .archive }
    if ["pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv"].contains(ext) { return .document }
    if ["swift", "rs", "py", "js", "ts", "tsx", "jsx", "json", "c", "h", "cpp", "go", "rb", "java", "kt", "o", "a", "dylib"].contains(ext) { return .development }
    return .other
  }
}

struct ExplorerEntry: Identifiable, Sendable {
  let path: String
  let parent: String?
  let identity: FileIdentity
  let kind: ExplorerKind
  let bytes: Int64?
  let logicalBytes: Int64?
  let modified: Date
  let hardLinks: UInt16
  let partial: Bool
  var id: String { path }
  var name: String { (path as NSString).lastPathComponent }
  var directory: Bool { kind == .folder }
}

struct ExplorerSnapshot: Sendable {
  let id = UUID()
  let root: URL
  let date: Date
  let entries: [String: ExplorerEntry]
  let ordered: [ExplorerEntry]
  let files: [ExplorerEntry]
  let children: [String: [ExplorerEntry]]
  let examined: Int
  let skipped: Int
  let excluded: Int
  let limited: Bool

  static func larger(_ a: ExplorerEntry, _ b: ExplorerEntry) -> Bool {
    a.bytes == b.bytes ? a.path < b.path : (a.bytes ?? -1) > (b.bytes ?? -1)
  }

  func rows(parent: String, mode: ExplorerMode, query: String, kind: ExplorerKind?, limit: Int = 500) -> [ExplorerEntry] {
    guard entries[parent]?.directory == true else { return [] }
    let prefix = parent == "/" ? "/" : parent + "/"
    let source = mode == .largest ? files : query.isEmpty ? children[parent] ?? [] : ordered
    let matching = source.lazy.filter {
      $0.path.hasPrefix(prefix) && (kind == nil || $0.kind == kind)
        && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query))
    }
    if mode == .largest {
      guard limit > 0 else { return [] }
      var seen = Set<FileIdentity>()
      var result: [ExplorerEntry] = []
      for row in matching where seen.insert(row.identity).inserted {
        result.append(row)
        if result.count == limit { break }
      }
      return result
    }
    return Array(matching)
  }

  func breadcrumbs(to path: String) -> [ExplorerEntry] {
    var trail: [ExplorerEntry] = [], next: String? = path
    while let key = next, let row = entries[key] {
      trail.append(row)
      next = row.parent
    }
    return trail.reversed()
  }
}

/// An explicit, bounded metadata scan. Navigation only reads the returned snapshot.
enum FolderExplorer {
  @concurrent static func scan(root: URL, maximumEntries: Int = 250_000, maximumDepth: Int = 128,
                              timeBudget: Duration = .seconds(30)) async throws -> ExplorerSnapshot {
    try Task.checkCancellation()
    guard !ScanExclusions.current.contains(root) else { throw CleanupFailure("This folder is excluded from scans.") }
    let deadline = ContinuousClock.now.advanced(by: timeBudget)
    var entries: [String: ExplorerEntry] = [:]
    var examined = 0, skipped = 0, excluded = 0, limited = false
    let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else { throw TrashFiles.posix() }
    var rootInfo = stat()
    guard fstat(fd, &rootInfo) == 0 else { close(fd); throw TrashFiles.posix() }
    let device = rootInfo.st_dev

    // Takes ownership of fd. Every child is opened relative to its pinned parent.
    func walk(_ fd: Int32, path: String, parent: String?, info: stat, depth: Int) throws -> (Int64?, Bool, [FileIdentity: Int64]) {
      guard let stream = fdopendir(fd) else {
        close(fd)
        skipped += 1
        entries[path] = make(path, parent, info, nil, true)
        return (nil, true, [:])
      }
      defer { closedir(stream) }
      var bytes: Int64 = 0, partial = false
      var linked: [FileIdentity: Int64] = [:]
      while true {
        try Task.checkCancellation()
        if examined >= max(0, maximumEntries) || depth >= max(0, maximumDepth) || ContinuousClock.now >= deadline {
          limited = true; partial = true; break
        }
        errno = 0
        guard let record = readdir(stream) else {
          if errno != 0 { partial = true; skipped += 1 }
          break
        }
        let name = withUnsafePointer(to: &record.pointee.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(record.pointee.d_namlen) + 1) { String(cString: $0) }
        }
        guard name != "." && name != ".." else { continue }
        examined += 1
        let url = URL(fileURLWithPath: path).appending(path: name)
        if ScanExclusions.current.contains(url) { excluded += 1; continue }
        var child = stat()
        guard fstatat(fd, name, &child, AT_SYMLINK_NOFOLLOW) == 0, child.st_dev == device else {
          skipped += 1; partial = true; continue
        }
        switch child.st_mode & S_IFMT {
        case S_IFDIR:
          let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          var opened = stat()
          guard childFD >= 0 else {
            skipped += 1; partial = true
            entries[url.path] = make(url.path, path, child, nil, true)
            continue
          }
          guard fstat(childFD, &opened) == 0, FileIdentity(opened) == FileIdentity(child) else {
            close(childFD); skipped += 1; partial = true; continue
          }
          let result = try walk(childFD, path: url.path, parent: path, info: opened, depth: depth + 1)
          bytes += result.0 ?? 0; partial = partial || result.1
          for (identity, size) in result.2 {
            if linked.updateValue(size, forKey: identity) != nil { bytes -= size }
          }
        case S_IFREG:
          let size = max(0, Int64(child.st_blocks) * 512)
          if child.st_nlink <= 1 || linked.updateValue(size, forKey: FileIdentity(child)) == nil { bytes += size }
          entries[url.path] = ExplorerEntry(path: url.path, parent: path, identity: FileIdentity(child),
            kind: .file(name), bytes: size, logicalBytes: child.st_size,
            modified: Date(timeIntervalSince1970: Double(child.st_mtimespec.tv_sec)), hardLinks: child.st_nlink, partial: false)
        default:
          skipped += 1; partial = true
        }
      }
      var after = stat()
      if fstat(fd, &after) != 0 || !FileComparison.stable(info, after) { partial = true }
      entries[path] = make(path, parent, info, bytes, partial)
      return (bytes, partial, linked)
    }
    func make(_ path: String, _ parent: String?, _ info: stat, _ bytes: Int64?, _ partial: Bool) -> ExplorerEntry {
      ExplorerEntry(path: path, parent: parent, identity: FileIdentity(info), kind: .folder, bytes: bytes,
        logicalBytes: nil, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)), hardLinks: 0, partial: partial)
    }
    _ = try walk(fd, path: root.path, parent: nil, info: rootInfo, depth: 0)
    try Task.checkCancellation()
    let ordered = entries.values.filter { $0.parent != nil }.sorted(by: ExplorerSnapshot.larger)
    let files = ordered.filter { !$0.directory }
    let children = Dictionary(grouping: ordered, by: { $0.parent! })
    return ExplorerSnapshot(root: root, date: .now, entries: entries, ordered: ordered, files: files,
      children: children, examined: examined, skipped: skipped, excluded: excluded, limited: limited)
  }
}
