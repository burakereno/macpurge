import CryptoKit
import Foundation
import SQLite3

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct ReportItem: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let name: String
  let category: String
  let path: String
  let bytes: Int64?
  let status: String
  let safety: String?
  let reason: String
  let basis: String
  let eligibleBytes: Int64
  let modified: Date?
  let parts: [String: Int64]
  let volume: Int32?

  var complete: Bool { status == "complete" }
  var estimated: Bool { basis == "tool" }
  var shortPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

struct ScanReport: Identifiable, Codable, Sendable {
  let id: UUID
  let date: Date
  let extended: Bool
  let free: Int64?
  let capacity: Int64?
  let items: [ReportItem]
  var groups: [String: Int64]? = nil
  var groupSafety: [String: SafetyBreakdown]? = nil
  var measuredGroupBytes: [String: Int64]? = nil // Includes lower bounds; older reports lack this field.

  static func make(
    roots: [ScanRoot], results: [String: RootSize], disk: VolumeReading?, extended: Bool,
    homeDevice: Int32?
  ) -> Self {
    var items: [ReportItem] = []
    for root in roots {
      guard let result = results[root.id], result.state != .absent else { continue }
      if root.group == .other && result.state == .complete && result.bytes < 500 * 1024 * 1024 {
        continue
      }
      var basis = "allocated"
      if case .report = root.source { basis = "tool" }
      let state: String =
        switch result.state {
        case .complete: "complete"
        case .partial: "partial"
        case .absent: "missing"
        case .unavailable: "unavailable"
        }
      func append(
        name: String, suffix: String, bytes: Int64?, candidate: Int64, profile: StorageProfile,
        parts: [String: Int64]
      ) {
        let assessment = profile.assessment(for: result.state)
        let reason: String
        if case .unavailable(let note) = result.state {
          reason = note
        } else {
          reason = assessment?.reason ?? "Ölçüm bilgisi"
        }
        let key = SHA256.hash(data: Data((root.id + suffix).utf8)).map {
          String(format: "%02x", $0)
        }.joined()
        let eligible =
          assessment?.level == .safe && result.state == .complete && basis == "allocated"
          && homeDevice != nil && homeDevice == result.measuredDevice
        items.append(
          .init(
            id: key, name: name, category: root.group.rawValue, path: root.url.path, bytes: bytes,
            status: state,
            safety: assessment?.level.rawValue, reason: reason, basis: basis,
            eligibleBytes: eligible ? max(0, candidate) : 0,
            modified: result.modified, parts: parts, volume: result.measuredDevice))
      }
      let parts = Dictionary(
        uniqueKeysWithValues: result.largest.sorted { a, b in
          a.value == b.value ? a.key < b.key : a.value > b.value
        }.prefix(5).map { ($0.key, $0.value) })
      if let device = root.device, result.measured {
        append(
          name: device.name + " · cihaz verileri", suffix: "/device",
          bytes: result.simulatorDataBytes, candidate: 0, profile: .simulatorData, parts: [:])
        append(
          name: device.name + " · önbellek", suffix: "/cache", bytes: result.simulatorCacheBytes,
          candidate: result.simulatorCacheBytes, profile: .simulatorCache, parts: [:])
      } else {
        append(
          name: root.title, suffix: "", bytes: result.measured ? result.bytes : nil,
          candidate: result.bytes - result.sharedLinkBytes, profile: root.profile, parts: parts)
      }
    }
    return .init(
      id: UUID(), date: .now, extended: extended, free: disk?.free, capacity: disk?.bytes,
      items: items.sorted { $0.bytes ?? -1 > $1.bytes ?? -1 })
  }

  func plan(target: Int64, excluding hidden: Set<String> = []) -> [ReportItem] {
    guard target > 0 else { return [] }
    var rows: [ReportItem] = []
    var sum: Int64 = 0
    for item in items.filter({ $0.eligibleBytes > 0 && !hidden.contains($0.id) }).sorted(by: {
      $0.eligibleBytes != $1.eligibleBytes ? $0.eligibleBytes > $1.eligibleBytes : $0.id < $1.id
    }) {
      guard sum < target else { break }
      rows.append(item)
      sum += item.eligibleBytes
    }
    return rows
  }

  func growth(since previous: Self?) -> [(ReportItem, Int64)] {
    guard let previous else { return [] }
    let old = Dictionary(
      previous.items.filter(\.complete).compactMap { item in item.bytes.map { (item.id, $0) } },
      uniquingKeysWith: max)
    return items.compactMap { item in
      guard item.complete, let bytes = item.bytes, let prior = old[item.id], bytes != prior else {
        return nil
      }
      return (item, bytes - prior)
    }.sorted { $0.1 > $1.1 }
  }

  func unusualGroups(previous: [Self]) -> [(String, Int64, Int64)] {
    let comparable = previous.filter { $0.id != id && $0.extended == extended }.prefix(14)
    return (groups ?? [:]).compactMap { name, bytes in
      let past = comparable.compactMap { $0.groups?[name] }.sorted()
      guard past.count >= 3 else { return nil }
      let middle = past.count / 2
      let median =
        past.count.isMultiple(of: 2)
        ? past[middle - 1] + (past[middle] - past[middle - 1]) / 2 : past[middle]
      let delta = bytes - median
      guard delta >= 2 * 1024 * 1024 * 1024, delta >= median / 2 else { return nil }
      return (name, bytes, delta)
    }.sorted { $0.2 > $1.2 }
  }

  func export(includePaths: Bool = false) throws -> Data {
    struct Row: Encodable {
      let id, name, group, status, measurement: String
      let bytes: Int64?
      let safety, path: String?
    }
    struct Payload: Encodable {
      let schemaVersion: Int
      let scannedAt: Date
      let freeBytes: Int64?
      let extended: Bool
      let items: [Row]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(
      Payload(
        schemaVersion: 1, scannedAt: date, freeBytes: free, extended: extended,
        items: items.map {
          Row(
            id: $0.id, name: $0.name, group: $0.category, status: $0.status, measurement: $0.basis,
            bytes: $0.bytes, safety: $0.safety, path: includePaths ? $0.path : nil)
        }))
  }
}

/// Stores only completed snapshots. Each operation owns its SQLite connection.
struct ScanArchive: Sendable {
  let file: URL
  static let standard = Self(
    file: URL.applicationSupportDirectory.appending(path: "MacPurge/History.sqlite"))
  struct Failure: LocalizedError { let errorDescription: String? }

  private func connection<T>(write: Bool, _ body: (OpaquePointer) throws -> T) throws -> T? {
    if write {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    } else if !FileManager.default.fileExists(atPath: file.path) {
      return nil
    }
    var db: OpaquePointer?
    let flags = write ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
    guard sqlite3_open_v2(file.path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      throw Failure(errorDescription: "Tarama geçmişi açılamadı.")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 2000)
    if write {
      try execute(
        db, "CREATE TABLE IF NOT EXISTS scans (t REAL PRIMARY KEY, payload BLOB NOT NULL)")
    }
    return try body(db)
  }

  private func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw Failure(errorDescription: String(cString: sqlite3_errmsg(db)))
    }
  }

  func read(limit: Int = 10) throws -> [ScanReport] {
    try connection(write: false) { db in
      var query: OpaquePointer?
      guard
        sqlite3_prepare_v2(db, "SELECT payload FROM scans ORDER BY t DESC LIMIT ?", -1, &query, nil)
          == SQLITE_OK
      else { throw Failure(errorDescription: "Geçmiş sorgulanamadı.") }
      defer { sqlite3_finalize(query) }
      sqlite3_bind_int(query, 1, Int32(clamping: limit))
      var rows: [ScanReport] = []
      while true {
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW, let ptr = sqlite3_column_blob(query, 0) else {
          throw Failure(errorDescription: "Geçmiş okunamadı.")
        }
        rows.append(
          try JSONDecoder().decode(
            ScanReport.self, from: Data(bytes: ptr, count: Int(sqlite3_column_bytes(query, 0)))))
      }
      return rows
    } ?? []
  }

  func save(_ report: ScanReport) throws {
    _ = try connection(write: true) { db in
      let data = try JSONEncoder().encode(report)
      try execute(db, "BEGIN IMMEDIATE")
      do {
        var query: OpaquePointer?
        guard
          sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO scans VALUES (?,?)", -1, &query, nil)
            == SQLITE_OK
        else { throw Failure(errorDescription: "Geçmiş yazılamadı.") }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, report.date.timeIntervalSince1970)
        let status = data.withUnsafeBytes { buf in
          sqlite3_bind_blob(
            query, 2, buf.baseAddress, Int32(buf.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          return sqlite3_step(query)
        }
        guard status == SQLITE_DONE else {
          throw Failure(errorDescription: "Geçmiş kaydedilemedi.")
        }
        try execute(
          db,
          "DELETE FROM scans WHERE t < unixepoch('now','-180 days') OR t NOT IN (SELECT t FROM scans ORDER BY t DESC LIMIT 400)"
        )
        try execute(db, "COMMIT")
      } catch {
        try? execute(db, "ROLLBACK")
        throw error
      }
    }
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: file.path) {
      _ = try connection(write: true) { db in
        try execute(db, "PRAGMA secure_delete=ON")
        try execute(db, "DELETE FROM scans")
      }
    }
  }
}

actor HistoryIO {
  static let shared = HistoryIO()
  func load() throws -> [ScanReport] { try ScanArchive.standard.read(limit: 35) }
  func record(_ report: ScanReport) throws { try ScanArchive.standard.save(report) }
  func clear() throws { try ScanArchive.standard.clear() }
}
