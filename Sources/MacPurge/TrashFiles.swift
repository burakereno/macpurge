import CryptoKit
import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct CleanupFailure: LocalizedError {
  let message: String
  let inUse: Bool
  init(_ message: String, inUse: Bool = false) { self.message = message; self.inUse = inUse }
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
  var sharedBytes: Int64 = 0
  var reclaimableBytes: Int64 { max(0, bytes - sharedBytes) }
}

/// Pin both parents. No path-based recursive removal or copy fallback is used.
enum TrashFiles {
  private struct LinkReading {
    var remaining: Int
    let bytes: Int64
  }

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
    _ url: URL, on device: Int32, allowSymlinks: Bool = false,
    download: PackageDownloadCache? = nil,
    fingerprint: Bool = true, review: ManualReview? = nil, development: DevelopmentCache? = nil,
    appCache: Bool = false
  ) throws
    -> CacheSnapshot
  {
    let appBundle = review?.applicationUninstall.map { $0.app.path == review?.path } == true
    return try directory(url.deletingLastPathComponent(), enumerate: false) { parent, parentInfo in
      if let review, review.file {
        var file = stat()
        guard fstatat(parent, url.lastPathComponent, &file, AT_SYMLINK_NOFOLLOW) == 0 else {
          throw posix()
        }
        guard file.st_mode & S_IFMT == S_IFREG, file.st_dev == device, file.st_uid == getuid()
        else { throw CleanupFailure("Sahip veya disk farklı.") }
        let signature =
          "\(file.st_mode)/\(file.st_size)/\(file.st_mtimespec.tv_sec)/\(file.st_mtimespec.tv_nsec)"
        return CacheSnapshot(
          parent: FileIdentity(parentInfo), identity: FileIdentity(file),
          changeSeconds: file.st_ctimespec.tv_sec, changeNanoseconds: file.st_ctimespec.tv_nsec,
          digest: Data(signature.utf8), bytes: Int64(file.st_blocks) * 512,
          sharedBytes: file.st_nlink > 1 ? Int64(file.st_blocks) * 512 : 0)
      }
      return try directory(url) { fd, info in
        guard info.st_dev == device, info.st_uid == getuid() || (appBundle && info.st_uid == 0) else {
          throw CleanupFailure("Farklı disk veya kullanıcıya ait klasör.")
        }
        if appBundle && info.st_flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE | SF_NOUNLINK) != 0 {
          throw CleanupFailure("macOS protects this application.")
        }
        try development?.validate(url)
        if development == .orphanIntermediates { try XcodeOrphanBuild.verifyOld(info) }
        var hash: SHA256? = fingerprint ? SHA256() : nil
        var links = [FileIdentity: LinkReading]()
        var bytes: Int64 = 0
        var sharedBlocks: Int64 = 0
        try walk(
          fd, device: device, depth: 0, allowSymlinks: allowSymlinks || review != nil, allowRootOwner: appBundle,
          download: download,
          downloadPrefix: "", hash: &hash, links: &links,
          bytes: &bytes, sharedBlocks: &sharedBlocks, development: development, relative: [], appCache: appCache)
        guard (review != nil && development != .orphanIntermediates)
          || links.values.allSatisfy({ $0.remaining == 0 }) else {
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
          digest: hash.map { Data($0.finalize()) } ?? Data(), bytes: bytes,
          sharedBytes: sharedBlocks + links.values.filter { $0.remaining > 0 }.reduce(0) { $0 + $1.bytes })
      }
    }
  }

  private static func walk(
    _ fd: Int32, device: Int32, depth: Int, allowSymlinks: Bool, allowRootOwner: Bool, download: PackageDownloadCache?,
    downloadPrefix: String, hash: inout SHA256?,
    links: inout [FileIdentity: LinkReading], bytes: inout Int64, sharedBlocks: inout Int64,
    development: DevelopmentCache?, relative: [String], appCache: Bool
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
    func inspect(_ name: String) throws {
      try Task.checkCancellation()
      var s = stat()
      guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
      guard s.st_dev == device, s.st_uid == getuid() || (allowRootOwner && s.st_uid == 0) else {
        throw CleanupFailure("Sahip veya disk farklı.")
      }
      let type = s.st_mode & S_IFMT
      guard type == S_IFREG || type == S_IFDIR || (allowSymlinks && type == S_IFLNK) else {
        throw CleanupFailure("Bağlantı veya özel dosya içeriyor.")
      }
      if let download, !download.accepts(name, directory: type == S_IFDIR, prefix: downloadPrefix) {
        throw CleanupFailure("Yarım indirme veya tanınmayan içerik var. Bu klasör taşınamaz.")
      }
      if appCache && !AppCacheRule.accepts(name) {
        throw CleanupFailure("This cache contains offline or profile data.")
      }
      let parts = development == nil ? [] : relative + [name]
      if let development {
        guard development.accepts(parts, directory: type == S_IFDIR, link: type == S_IFLNK)
        else { throw CleanupFailure("Unrecognized contents in this developer cache.") }
        try development.validateEntry(parts, in: fd, info: s)
      }
      let entrySharedBlocks = development == .orphanIntermediates
        ? try XcodeOrphanBuild.sharedBytes(for: parts, in: fd, info: s) : 0
      hash?.update(data: Data(name.utf8))
      hash?.update(data: Data([0]))
      hash?.update(
        data: Data(
          "\(depth) \(s.st_ino) \(s.st_mode) \(s.st_size) \(s.st_nlink) \(s.st_ctimespec.tv_sec) \(s.st_ctimespec.tv_nsec)\n"
            .utf8))
      // Generated framework links move as directory entries. Never open or follow their destination.
      if type == S_IFLNK { return }
      if type == S_IFREG {
        let key = FileIdentity(s)
        if links[key] != nil {
          links[key]?.remaining -= 1
        } else {
          bytes += Int64(s.st_blocks) * 512
          sharedBlocks += entrySharedBlocks
          if s.st_nlink > 1 {
            links[key] = LinkReading(remaining: Int(s.st_nlink) - 1, bytes: Int64(s.st_blocks) * 512)
          }
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
          child, device: device, depth: depth + 1, allowSymlinks: allowSymlinks, allowRootOwner: allowRootOwner, download: download,
          downloadPrefix: download == nil ? "" : downloadPrefix + name, hash: &hash,
          links: &links, bytes: &bytes, sharedBlocks: &sharedBlocks, development: development, relative: parts, appCache: appCache)
      }
    }
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
      if name == "." || name == ".." { continue }
      if hash == nil { try inspect(name) } else { names.append(name) }
    }
    for name in names.sorted() { try inspect(name) }
  }

  /// Exclusive rename on one volume. A recreated cache is never replaced on undo.
  static func move(
    _ source: URL, to destination: URL, identity: FileIdentity,
    sourceParent: FileIdentity?, destinationParent: FileIdentity?, file: Bool = false
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
          item.st_mode & S_IFMT == (file ? S_IFREG : S_IFDIR), FileIdentity(item) == identity
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
