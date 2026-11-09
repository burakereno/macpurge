import Foundation

/// The v11 SQLite index stores MessagePack objects with msgpackr's inline record extension.
/// Reject extensions outside the observed index format so a new format cannot look like an empty index.
struct PnpmIndexMessagePack {
  private enum Invalid: Error { case format }
  private let bytes: [UInt8]
  private var position = 0
  private var records: [UInt8: [String]] = [:]

  init(_ data: Data) { bytes = Array(data) }

  mutating func readRoot() throws -> Any {
    let value = try read(depth: 0)
    guard position == bytes.count else { throw Invalid.format }
    return value
  }

  private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
    guard count >= 0, count <= bytes.count - position else { throw Invalid.format }
    let start = position
    position += count
    return bytes[start..<position]
  }

  private mutating func byte() throws -> UInt8 {
    guard position < bytes.count else { throw Invalid.format }
    defer { position += 1 }
    return bytes[position]
  }

  private mutating func integer(_ count: Int) throws -> UInt64 {
    try take(count).reduce(0) { ($0 << 8) | UInt64($1) }
  }

  private mutating func string(_ count: Int) throws -> String {
    guard let value = String(bytes: try take(count), encoding: .utf8) else { throw Invalid.format }
    return value
  }

  private mutating func array(_ count: Int, depth: Int) throws -> [Any] {
    guard count <= bytes.count - position else { throw Invalid.format }
    return try (0..<count).map { _ in try read(depth: depth) }
  }

  private mutating func map(_ count: Int, depth: Int) throws -> [String: Any] {
    guard count <= (bytes.count - position) / 2 else { throw Invalid.format }
    var values: [String: Any] = [:]
    for _ in 0..<count {
      guard let key = try read(depth: depth) as? String else { throw Invalid.format }
      values[key] = try read(depth: depth)
    }
    return values
  }

  private mutating func record(_ keys: [String], depth: Int) throws -> [String: Any] {
    guard keys.count <= bytes.count - position else { throw Invalid.format }
    var values: [String: Any] = [:]
    for key in keys { values[key] = try read(depth: depth) }
    return values
  }

  private mutating func read(depth: Int) throws -> Any {
    guard depth < 64 else { throw Invalid.format }
    let child = depth + 1
    let token = try byte()
    switch token {
    case 0x00...0x7f:
      if let keys = records[token] { return try record(keys, depth: child) }
      return Int(token)
    case 0x80...0x8f: return try map(Int(token & 0x0f), depth: child)
    case 0x90...0x9f: return try array(Int(token & 0x0f), depth: child)
    case 0xa0...0xbf: return try string(Int(token & 0x1f))
    case 0xc0: return NSNull()
    case 0xc2, 0xc3: return token == 0xc3
    case 0xc4, 0xc5, 0xc6:
      let count = Int(try integer(1 << Int(token - 0xc4)))
      return Data(try take(count))
    case 0xca: return Float(bitPattern: UInt32(try integer(4)))
    case 0xcb: return Double(bitPattern: try integer(8))
    case 0xcc...0xcf: return Int(truncatingIfNeeded: try integer(1 << Int(token - 0xcc)))
    case 0xd0: return Int(Int8(bitPattern: try byte()))
    case 0xd1: return Int(Int16(bitPattern: UInt16(try integer(2))))
    case 0xd2: return Int(Int32(bitPattern: UInt32(try integer(4))))
    case 0xd3: return Int(Int64(bitPattern: try integer(8)))
    case 0xd4:
      let type = try byte()
      let id = try byte()
      if type == 0 { return NSNull() }
      guard type == 0x72, (0x40...0x7f).contains(id),
        let keys = try read(depth: child) as? [String] else { throw Invalid.format }
      records[id] = keys
      return try record(keys, depth: child)
    case 0xd9, 0xda, 0xdb:
      let count = Int(try integer(1 << Int(token - 0xd9)))
      return try string(count)
    case 0xdc, 0xdd:
      let count = Int(try integer(token == 0xdc ? 2 : 4))
      return try array(count, depth: child)
    case 0xde, 0xdf:
      let count = Int(try integer(token == 0xde ? 2 : 4))
      return try map(count, depth: child)
    case 0xe0...0xff: return Int(Int8(bitPattern: token))
    default: throw Invalid.format
    }
  }
}
