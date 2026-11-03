import CryptoKit
import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct CleanupFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { ReviewLanguage.text(message) }
}

struct FileIdentity: Codable, Hashable, Sendable {
  let device: Int32
  let inode: UInt64
  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
  }
}

struct CacheSnapshot: Equatable, Sendable {
  let parent: FileIdentity
  let identity: FileIdentity
  let changeSeconds: Int
  let changeNanoseconds: Int
  let digest: Data
  let bytes: Int64
}

/// Pin both parents. No path-based recursive removal or copy fallback is used.
enum TrashFiles {
  static func directory<T>(_ url: URL, enumerate: Bool = true, _ work: (Int32, stat) throws -> T)
    throws -> T
  {
    let access = enumerate ? O_RDONLY : O_SEARCH
    let fd = open(url.path, access | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else { throw posix() }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw posix() }
    return try work(fd, info)
  }

  static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

  static func snapshot(
    _ url: URL, on device: Int32, allowSymlinks: Bool = false, download: PackageDownloadCache? = nil
  ) throws
    -> CacheSnapshot
  {
    try directory(url.deletingLastPathComponent(), enumerate: false) { parent, parentInfo in
      try directory(url) { fd, info in
        guard info.st_dev == device, info.st_uid == getuid() else {
          throw CleanupFailure("Farklı disk veya kullanıcıya ait klasör.")
        }
        var hash = SHA256()
        var links = [FileIdentity: Int]()
        var bytes: Int64 = 0
        try walk(
          fd, device: device, depth: 0, allowSymlinks: allowSymlinks, download: download,
          downloadPrefix: "", hash: &hash, links: &links,
          bytes: &bytes)
        guard links.values.allSatisfy({ $0 == 0 }) else {
          throw CleanupFailure("Klasör dışında bağlantısı olan dosya içeriyor.")
        }
        var check = stat()
        guard fstatat(parent, url.lastPathComponent, &check, AT_SYMLINK_NOFOLLOW) == 0,
          FileIdentity(check) == FileIdentity(info),
          check.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
          check.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
        else { throw CleanupFailure("Klasör değişti.") }
        return CacheSnapshot(
          parent: FileIdentity(parentInfo), identity: FileIdentity(info),
          changeSeconds: info.st_ctimespec.tv_sec, changeNanoseconds: info.st_ctimespec.tv_nsec,
          digest: Data(hash.finalize()), bytes: bytes)
      }
    }
  }

  private static func walk(
    _ fd: Int32, device: Int32, depth: Int, allowSymlinks: Bool, download: PackageDownloadCache?,
    downloadPrefix: String, hash: inout SHA256,
    links: inout [FileIdentity: Int], bytes: inout Int64
  ) throws {
    guard depth < 160 else { throw CleanupFailure("Klasör çok derin.") }
    let copy = dup(fd)
    guard copy >= 0 else { throw posix() }
    guard let dir = fdopendir(copy) else {
      let error = posix()
      close(copy)
      throw error
    }
    defer { closedir(dir) }
    var names: [String] = []
    while true {
      try Task.checkCancellation()
      errno = 0
      guard let entry = readdir(dir) else {
        if errno != 0 { throw posix() }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else { throw CleanupFailure("Dosya adı doğrulanamadı.") }
      if name != "." && name != ".." { names.append(name) }
    }
    for name in names.sorted() {
      try Task.checkCancellation()
      var s = stat()
      guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
      guard s.st_dev == device, s.st_uid == getuid() else {
        throw CleanupFailure("Sahip veya disk farklı.")
      }
      let type = s.st_mode & S_IFMT
      guard type == S_IFREG || type == S_IFDIR || (allowSymlinks && type == S_IFLNK) else {
        throw CleanupFailure("Bağlantı veya özel dosya içeriyor.")
      }
      if let download, !download.accepts(name, directory: type == S_IFDIR, prefix: downloadPrefix) {
        throw CleanupFailure("Yarım indirme veya tanınmayan içerik var. Bu klasör taşınamaz.")
      }
      hash.update(data: Data(name.utf8))
      hash.update(data: Data([0]))
      hash.update(
        data: Data(
          "\(depth) \(s.st_ino) \(s.st_mode) \(s.st_size) \(s.st_nlink) \(s.st_ctimespec.tv_sec) \(s.st_ctimespec.tv_nsec)\n"
            .utf8))
      // Generated framework links move as directory entries. Never open or follow their destination.
      if type == S_IFLNK { continue }
      if type == S_IFREG {
        let key = FileIdentity(s)
        if let remaining = links[key] {
          links[key] = remaining - 1
        } else {
          bytes += Int64(s.st_blocks) * 512
          if s.st_nlink > 1 { links[key] = Int(s.st_nlink) - 1 }
        }
      } else {
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw posix() }
        defer { close(child) }
        var opened = stat()
        guard fstat(child, &opened) == 0, FileIdentity(opened) == FileIdentity(s) else {
          throw CleanupFailure("Klasör ölçülürken değişti.")
        }
        try walk(
          child, device: device, depth: depth + 1, allowSymlinks: allowSymlinks, download: download,
          downloadPrefix: download == nil ? "" : downloadPrefix + name, hash: &hash,
          links: &links, bytes: &bytes)
      }
    }
  }

  /// Exclusive rename on one volume. A recreated cache is never replaced on undo.
  static func move(
    _ source: URL, to destination: URL, identity: FileIdentity,
    sourceParent: FileIdentity?, destinationParent: FileIdentity?
  ) throws {
    try directory(source.deletingLastPathComponent(), enumerate: false) { from, fromInfo in
      try directory(destination.deletingLastPathComponent(), enumerate: false) { to, toInfo in
        guard fromInfo.st_dev == identity.device, toInfo.st_dev == identity.device,
          sourceParent.map({ $0 == FileIdentity(fromInfo) }) ?? true,
          destinationParent.map({ $0 == FileIdentity(toInfo) }) ?? true
        else {
          throw CleanupFailure("Üst klasör veya disk değişti.")
        }
        let original = source.lastPathComponent
        let next = destination.lastPathComponent
        var item = stat()
        guard fstatat(from, original, &item, AT_SYMLINK_NOFOLLOW) == 0,
          item.st_mode & S_IFMT == S_IFDIR, FileIdentity(item) == identity
        else {
          throw CleanupFailure("Öğe taşınmış veya değiştirilmiş.")
        }
        guard renameatx_np(from, original, to, next, UInt32(RENAME_EXCL)) == 0 else {
          if errno == EEXIST { throw CleanupFailure("Hedefte aynı adlı bir öğe var.") }
          throw posix()
        }
        guard fstatat(to, next, &item, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity(item) == identity
        else {
          _ = renameatx_np(to, next, from, original, UInt32(RENAME_EXCL))
          throw CleanupFailure("Öğe işlem sırasında değişti. İki konumu da kontrol et.")
        }
      }
    }
  }
}
