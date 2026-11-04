import Darwin
import Foundation

// Changes through a hard link outside a watched tree need not change its recursive generation.
struct LinkCheck: Sendable {
  let path: String
  let changeSeconds: Int
  let changeNanoseconds: Int
  let linkCount: nlink_t
  init(path: String, info: stat) {
    self.path = path
    changeSeconds = info.st_ctimespec.tv_sec
    changeNanoseconds = info.st_ctimespec.tv_nsec
    linkCount = info.st_nlink
  }
  func matches(_ key: FileKey, in dir: Int32) -> Bool {
    let fd = openat(dir, path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var s = stat()
    return fstat(fd, &s) == 0 && s.st_dev == key.device && s.st_ino == key.inode
      && s.st_ctimespec.tv_sec == changeSeconds && s.st_ctimespec.tv_nsec == changeNanoseconds
      && s.st_nlink == linkCount
  }
}

/// APFS supplies a recursive generation only for trees whose directory statistics
/// it maintains. Zero, unsupported filesystems and missing permissions all mean
/// "walk again". A directory's own mtime is not a substitute for this value.
package actor MeasurementCache {
  static let linkLimit = 65_536
  package static let shared = MeasurementCache()
  private var paths = Set<String>()
  private var rows: [String: (Ticket, RootSize)] = [:]
  package private(set) var hits = 0

  package struct Ticket: Equatable, Sendable {
    let cleanupPatterns: Set<String>
    let excludedDirectories: Set<String>
    let generation: UInt64
    let device: dev_t
    let inode: ino_t
    let changeSeconds: Int
    let changeNanoseconds: Int
  }

  package func configure(_ roots: [ScanRoot], preserveEntries: Bool = false) {
    paths = Set(roots.filter { $0.source == .directory }.map(\.url.path))
    if preserveEntries { return }
    let ids = Set(roots.map(\.id))
    rows = rows.filter { ids.contains($0.key) }
  }

  package func stop() {
    paths.removeAll()
    rows.removeAll()
  }

  package func ticket(_ root: ScanRoot) -> Ticket? {
    // Age buckets change with time even when no files change.
    guard root.group != .temp, paths.contains(root.url.path) else { return nil }
    let fd = open(root.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, root.expectedDevice == nil || root.expectedDevice == info.st_dev
    else { return nil }
    var request = attrlist()
    request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    request.forkattr = attrgroup_t(ATTR_CMNEXT_RECURSIVE_GENCOUNT)
    // Packed kernel response: byte length, five returned-attribute masks, UInt64.
    var response = [UInt8](repeating: 0, count: 32)
    let generation: UInt64? = response.withUnsafeMutableBytes { bytes in
      guard
        fgetattrlist(fd, &request, bytes.baseAddress, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
          == 0,
        bytes.loadUnaligned(as: UInt32.self) >= 32,
        bytes.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
          & UInt32(ATTR_CMNEXT_RECURSIVE_GENCOUNT) != 0
      else { return nil }
      return bytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
    }
    guard let generation, generation != 0 else { return nil }
    return Ticket(
      cleanupPatterns: root.cleanupPatterns, excludedDirectories: root.excludedDirectories,
      generation: generation, device: info.st_dev,
      inode: info.st_ino,
      changeSeconds: info.st_ctimespec.tv_sec, changeNanoseconds: info.st_ctimespec.tv_nsec)
  }

  package func cached(_ root: ScanRoot, _ ticket: Ticket?) -> RootSize? {
    guard let ticket, let entry = rows[root.id], entry.0 == ticket else { return nil }
    if !entry.1.linkChecks.isEmpty {
      let dir = open(root.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
      guard dir >= 0 else { return nil }
      defer { close(dir) }
      for (key, check) in entry.1.linkChecks {
        if Task.isCancelled || !check.matches(key, in: dir) { return nil }
      }
      guard self.ticket(root) == ticket else { return nil }
    }
    hits += 1
    return entry.1
  }

  package func store(_ row: RootSize, for root: ScanRoot, before: Ticket?) {
    guard let before, row.state == .complete, row.links.count == row.linkChecks.count,
      ticket(root) == before
    else {
      rows.removeValue(forKey: root.id)
      return
    }
    if !row.links.isEmpty {
      let retained = rows.reduce(0) { $0 + ($1.key == root.id ? 0 : $1.value.1.linkChecks.count) }
      guard retained + row.links.count <= Self.linkLimit else {
        rows.removeValue(forKey: root.id)
        return
      }
    }
    rows[root.id] = (before, row)
  }
}
