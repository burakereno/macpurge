import CryptoKit
import Darwin
import Foundation

struct FileProof: Codable, Equatable, Sendable {
  let path: String
  let identity: FileIdentity
  let logicalBytes: Int64
  let allocatedBytes: Int64
  let links: UInt16
  let modifiedSeconds: Int
  let modifiedNanos: Int
  let changedSeconds: Int
  let changedNanos: Int
  let digest: Data
  let mayShareBlocks: Bool?
}

enum FileComparison {
  static func privateAllocatedBytes(_ fd: Int32) -> Int64? {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    var response = [UInt8](repeating: 0, count: 32)
    return response.withUnsafeMutableBytes { data in
      guard fgetattrlist(fd, &attributes, data.baseAddress, data.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0,
        data.loadUnaligned(as: UInt32.self) >= 32,
        data.loadUnaligned(fromByteOffset: 20, as: UInt32.self) & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0
      else { return nil }
      let bytes = data.loadUnaligned(fromByteOffset: 24, as: Int64.self)
      return bytes >= 0 ? bytes : nil
    }
  }

  static func mayShareBlocks(_ fd: Int32) -> Bool? {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    attributes.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
    var response = [UInt8](repeating: 0, count: 40)
    return response.withUnsafeMutableBytes { data in
      guard fgetattrlist(fd, &attributes, data.baseAddress, data.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0,
        data.loadUnaligned(as: UInt32.self) >= 40,
        data.loadUnaligned(fromByteOffset: 20, as: UInt32.self) & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 else { return nil }
      return data.loadUnaligned(fromByteOffset: 32, as: UInt64.self) & UInt64(EF_MAY_SHARE_BLOCKS) != 0
    }
  }
  static func read<T>(_ url: URL, _ body: (Int32, stat) throws -> T) throws -> T {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw CleanupFailure("The file could not be verified. Search again.")
    }
    return try body(fd, info)
  }

  static func proof(_ url: URL, prefix: Bool = false, expectedBytes: Int64? = nil) throws -> FileProof {
    try read(url) { fd, before in
      guard expectedBytes == nil || before.st_size == expectedBytes else {
        throw CleanupFailure("The file changed while it was being compared. Search again.")
      }
      var hash = SHA256()
      var buffer = [UInt8](repeating: 0, count: 65536)
      var total: Int64 = 0
      let limit = prefix ? min(before.st_size, Int64(buffer.count)) : before.st_size
      while total < limit {
        try Task.checkCancellation()
        let n = Darwin.read(fd, &buffer, Int(min(Int64(buffer.count), limit - total)))
        if n == 0 { break }
        if n < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
        hash.update(data: Data(buffer.prefix(n)))
        total += Int64(n)
      }
      var after = stat()
      guard fstat(fd, &after) == 0, stable(before, after), total == limit else {
        throw CleanupFailure("The file changed while it was being compared. Search again.")
      }
      let shared = mayShareBlocks(fd)
      return FileProof(path: url.path, identity: FileIdentity(before), logicalBytes: before.st_size,
        allocatedBytes: Int64(before.st_blocks) * 512, links: before.st_nlink,
        modifiedSeconds: before.st_mtimespec.tv_sec, modifiedNanos: before.st_mtimespec.tv_nsec,
        changedSeconds: before.st_ctimespec.tv_sec, changedNanos: before.st_ctimespec.tv_nsec,
        digest: Data(hash.finalize()), mayShareBlocks: shared)
    }
  }

  static func stable(_ a: stat, _ b: stat) -> Bool {
    FileIdentity(a) == FileIdentity(b) && a.st_size == b.st_size && a.st_nlink == b.st_nlink
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }

  static func equal(_ a: URL, _ b: URL, expectedBytes: Int64? = nil) throws -> Bool {
    try read(a) { first, aInfo in
      try read(b) { second, bInfo in
        guard FileIdentity(aInfo) != FileIdentity(bInfo), aInfo.st_size == bInfo.st_size,
          expectedBytes == nil || aInfo.st_size == expectedBytes else { return false }
        var aBuffer = [UInt8](repeating: 0, count: 65536)
        var bBuffer = aBuffer
        var offset: off_t = 0
        while offset < aInfo.st_size {
          try Task.checkCancellation()
          let count = min(aBuffer.count, Int(aInfo.st_size - offset))
          let aCount = pread(first, &aBuffer, count, offset)
          let bCount = pread(second, &bBuffer, count, offset)
          guard aCount == count, bCount == count else { throw CleanupFailure("The file changed while it was being compared. Search again.") }
          guard aBuffer.prefix(count).elementsEqual(bBuffer.prefix(count)) else { return false }
          offset += off_t(count)
        }
        var aEnd = stat(), bEnd = stat()
        return fstat(first, &aEnd) == 0 && fstat(second, &bEnd) == 0 && stable(aInfo, aEnd) && stable(bInfo, bEnd)
      }
    }
  }
}
