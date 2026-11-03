import Darwin
import Foundation

/// APFS supplies a recursive generation only for trees whose directory statistics
/// it maintains. Zero, unsupported filesystems and missing permissions all mean
/// "walk again". A directory's own mtime is not a substitute for this value.
package actor MeasurementCache {
  package static let shared = MeasurementCache()
  private var paths = Set<String>()
  private var rows: [String: (Ticket, RootSize)] = [:]
  package private(set) var hits = 0

  package struct Ticket: Equatable, Sendable {
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
    guard paths.contains(root.url.path) else { return nil }
    let fd = open(root.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return nil }
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
      excludedDirectories: root.excludedDirectories, generation: generation, device: info.st_dev,
      inode: info.st_ino,
      changeSeconds: info.st_ctimespec.tv_sec, changeNanoseconds: info.st_ctimespec.tv_nsec)
  }

  package func cached(_ root: ScanRoot, _ ticket: Ticket?) -> RootSize? {
    guard let ticket, let entry = rows[root.id], entry.0 == ticket else { return nil }
    hits += 1
    return entry.1
  }

  package func store(_ row: RootSize, for root: ScanRoot, before: Ticket?) {
    guard let before, row.state == .complete, row.links.isEmpty, ticket(root) == before else {
      rows.removeValue(forKey: root.id)
      return
    }
    rows[root.id] = (before, row)
  }
}
