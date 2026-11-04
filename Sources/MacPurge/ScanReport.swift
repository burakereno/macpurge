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
  var bytes: Int64?
  let status: String
  let safety: String?
  let reason: String
  let basis: String
  var eligibleBytes: Int64
  let modified: Date?
  let parts: [String: Int64]
  let volume: Int32?
  var simulatorDataDevice: SimulatorDevice? = nil
  var workspace: String? = nil
  var runtimeUsage: RuntimeUsage? = nil
  var directoryInode: UInt64? = nil
  var age: FileAgeBreakdown? = nil
  // Nil uses the date of the full scan. A cleanup only advances rows actually remeasured.
  var measuredAt: Date? = nil
  var containsExcludedFolders: Bool? = nil
  var sharedLinkBytes: Int64? = nil
  var reclaimableBytes: Int64 { max(0, (bytes ?? 0) - (sharedLinkBytes ?? 0)) }

  var complete: Bool { status == "complete" }
  var actionTitle: String {
    if category == ScanGroup.packages.rawValue && path.hasSuffix("/.npm/_cacache") {
      return ReviewLanguage.text("npm önbelleğini temizle")
    }
    if name == (path as NSString).lastPathComponent { return name }
    for (suffix, key) in Self.generatedSuffixes where name.hasSuffix(suffix) {
      return ReviewLanguage.format(key, String(name.dropLast(suffix.count)))
    }
    return ReviewLanguage.text(name)
  }
  // Localize generated names at display time, including names in previous scans.
  private static let generatedSuffixes = [
    (" · cihaz verileri", "%@ · cihaz verileri"), (" · önbellek", "%@ · önbellek"),
    (" · SDK/cihaz eşleşmesi yok", "%@ · SDK/cihaz eşleşmesi yok"),
    (" · Derleme ara çıktıları", "%@ · Derleme ara çıktıları"),
  ]
  var estimated: Bool { basis == "tool" }
  var safePlanCandidate: Bool {
    complete && basis == "allocated" && safety == SafetyLevel.safe.rawValue && eligibleBytes > 0
  }
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
  var measuredGroupBytes: [String: Int64]? = nil  // Includes lower bounds; older reports lack this field.

  var scope: String? = nil  // Old snapshots can be viewed, but do not describe their full scan scope.

  static func scopeKey(extended: Bool, protected: Bool, projects: [URL], exclusions: [String] = []) -> String {
    let fields =
      [
        "storage-v2", extended ? "detailed" : "quick",
        extended && protected ? "protected" : "standard",
      ] + projects.map(\.path).sorted()
      + (exclusions.isEmpty ? [] : ["exclusions"] + exclusions.sorted())
    return SHA256.hash(data: Data(fields.joined(separator: "\0").utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  func previous(in history: [Self]) -> Self? {
    guard let scope else { return nil }
    return history.first {
      $0.id != id && $0.date < date && $0.scope == scope && $0.extended == extended
    }
  }

  func makeDeltas(since previous: Self?) -> [String: Int64] {
    guard let previous, let scope, scope == previous.scope, extended == previous.extended,
      let groups, let prior = previous.groups
    else { return [:] }
    return groups.reduce(into: [:]) { deltas, entry in
      if let before = prior[entry.key], before != entry.value {
        deltas[entry.key] = entry.value - before
      }
    }
  }

  static func make(
    roots: [ScanRoot], results: [String: RootSize], disk: VolumeReading?, extended: Bool,
    homeDevice: Int32?
  ) -> Self {
    let items = makeItems(roots: roots, results: results, homeDevice: homeDevice)
    return .init(
      id: UUID(), date: .now, extended: extended, free: disk?.free, capacity: disk?.bytes,
      items: items.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) })
  }

  static func itemID(_ root: ScanRoot, suffix: String = "") -> String {
    SHA256.hash(data: Data((root.id + suffix).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func makeItems(
    roots: [ScanRoot], results: [String: RootSize], homeDevice: Int32?
  ) -> [ReportItem] {
    var items: [ReportItem] = []
    for root in roots {
      guard let result = results[root.id], result.state != .absent, root.includedInInventory(result)
      else { continue }
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
        let key = itemID(root, suffix: suffix)
        let eligible =
          assessment?.level == .safe && result.state == .complete && basis == "allocated"
          && (profile != .simulatorCache || root.device != nil)
          && homeDevice != nil && homeDevice == result.measuredDevice
        items.append(
          .init(
            id: key, name: name, category: root.group.rawValue, path: root.url.path, bytes: bytes,
            status: state,
            safety: assessment?.level.rawValue, reason: reason, basis: basis,
            eligibleBytes: eligible && !root.containsScanExclusions ? max(0, candidate) : 0,
            modified: result.modified, parts: parts, volume: result.measuredDevice,
            simulatorDataDevice: profile == .simulatorData ? root.device : nil,
            workspace: root.workspace, runtimeUsage: root.runtimeUsage,
            directoryInode: result.measuredInode, age: result.measured ? result.age : nil,
            containsExcludedFolders: root.containsScanExclusions ? true : nil,
            sharedLinkBytes: profile == .simulatorData
              ? min(bytes ?? 0, result.sharedLinkBytes) : max(0, (bytes ?? 0) - candidate)))
      }
      let parts = Dictionary(
        uniqueKeysWithValues: result.largestFive.map { ($0.key, $0.value) })
      if let device = root.device, result.measured {
        append(
          name: device.name + " · cihaz verileri", suffix: "/device",
          bytes: result.simulatorDataBytes, candidate: 0, profile: .simulatorData, parts: [:])
        append(
          name: device.name + " · önbellek", suffix: "/cache", bytes: result.simulatorCacheBytes,
          candidate: result.simulatorCacheBytes, profile: .simulatorCache, parts: [:])
      } else {
        append(
          name: root.displayTitle,
          suffix: root.group == .packages && !root.excludedDirectories.isEmpty ? "/remainder" : "",
          bytes: result.measured ? result.bytes : nil,
          candidate: result.bytes - result.sharedLinkBytes, profile: root.effectiveProfile(result),
          parts: parts)
      }
    }
    return items
  }

  func safeItemsByCategory(excluding hidden: Set<String>) -> [String: [ReportItem]] {
    Dictionary(
      grouping: items.filter { $0.safety == SafetyLevel.safe.rawValue && !hidden.contains($0.id) },
      by: \.category)
  }

  func movableItems(_ ids: Set<String>, states: [String: MoveAvailability], hidden: Set<String>)
    -> [ReportItem]
  {
    items.filter {
      ids.contains($0.id) && !hidden.contains($0.id) && $0.safePlanCandidate
        && states[$0.id] == .ready
    }
  }

  func rankedCandidates(
    excluding hidden: Set<String>, moveStates: [String: MoveAvailability],
    regrowth: [RegrownFolder], at now: Date = .now, actionBytes: [String: Int64] = [:]
  ) -> [ReportItem] {
    let candidates = items.filter {
      $0.safePlanCandidate && !hidden.contains($0.id) && moveStates[$0.id] == .ready
    }.map { row in
      var row = row
      if let bytes = actionBytes[row.id] { row.eligibleBytes = bytes }
      return row
    }
    let deferred = RegrownFolder.deferredIDs(regrowth, candidates: candidates, at: now)
    return candidates.sorted { a, b in
      let later = deferred.contains(a.id)
      if later != deferred.contains(b.id) { return !later }
      return a.eligibleBytes != b.eligibleBytes ? a.eligibleBytes > b.eligibleBytes : a.id < b.id
    }
  }

  func plan(
    target: Int64, excluding hidden: Set<String> = [], moveStates: [String: MoveAvailability],
    regrowth: [RegrownFolder] = [], at now: Date = .now, actionBytes: [String: Int64] = [:]
  ) -> [ReportItem] {
    guard target > 0 else { return [] }
    var rows: [ReportItem] = []
    var remaining = target
    for item in rankedCandidates(
      excluding: hidden, moveStates: moveStates, regrowth: regrowth, at: now, actionBytes: actionBytes)
    {
      rows.append(item)
      if item.eligibleBytes >= remaining { break }
      remaining -= item.eligibleBytes
    }
    return rows
  }

  func growth(since previous: Self?) -> [(ReportItem, Int64)] {
    guard let previous, let scope, previous.scope == scope, previous.extended == extended else {
      return []
    }
    let old = Dictionary(
      previous.items.filter(\.complete).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return items.compactMap { item in
      guard item.complete, let bytes = item.bytes, let prior = old[item.id],
        prior.volume == item.volume, prior.workspace == item.workspace, prior.basis == item.basis,
        let before = prior.bytes, bytes != before
      else { return nil }
      return (item, bytes - before)
    }.sorted { $0.1 > $1.1 }
  }

  func unusualGroups(previous: [Self]) -> [(String, Int64, Int64)] {
    guard let scope else { return [] }
    let comparable = previous.filter { $0.id != id && $0.scope == scope && $0.extended == extended }
      .prefix(14)
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
      let age: FileAgeBreakdown?
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
            bytes: $0.bytes, safety: $0.safety, path: includePaths ? $0.path : nil, age: $0.age)
        }))
  }
}

/// One scan owns this accumulator. Keep report construction off the UI actor and build each row once.
actor ScanReportBuilder {
  let id: UUID
  let scope: String
  let extended: Bool
  let disk: VolumeReading?
  let device: Int32?
  private var items: [ReportItem] = []

  init(id: UUID, scope: String, extended: Bool, disk: VolumeReading?, device: Int32?) {
    self.id = id
    self.scope = scope
    self.extended = extended
    self.disk = disk
    self.device = device
  }

  func append(_ roots: [ScanRoot], results: [String: RootSize]) {
    items += ScanReport.makeItems(roots: roots, results: results, homeDevice: device)
  }

  func snapshot(
    roots: [ScanRoot], results: [String: RootSize], sizes: [ScanGroup: GroupSize],
    pending: Set<ScanGroup>, simulatorListIncomplete: Bool,
    last: ScanReport?, final: Bool = false
  ) -> ScanReport {
    var groups: [String: Int64] = [:]
    var incomplete = pending
    if simulatorListIncomplete { incomplete.insert(.simulators) }
    for root in roots {
      if results[root.id]?.state != .complete && results[root.id]?.state != .absent {
        incomplete.insert(root.group)
      }
      groups[root.group.rawValue] = sizes[root.group]?.bytes ?? 0
    }
    for group in incomplete { groups.removeValue(forKey: group.rawValue) }
    var safety: [String: SafetyBreakdown] = [:]
    for (group, size) in sizes { safety[group.rawValue] = size.breakdown }
    let report = ScanReport(
      id: id, date: .now, extended: extended, free: disk?.free,
      capacity: disk?.bytes,
      items: final ? items.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) } : items,
      groups: groups, groupSafety: safety, measuredGroupBytes: safety.mapValues(\.total),
      scope: scope)
    return report.retainingPending(pending, from: last)
  }
}

/// Stores only completed snapshots. Each operation owns its SQLite connection.
struct ScanArchive: Sendable {
  let file: URL
  static let standard = Self(
    file: BuildIdentity.supportDirectory.appending(path: "History.sqlite"))
  struct Failure: LocalizedError {
    let errorDescription: String?
    init(errorDescription: String) { self.errorDescription = ReviewLanguage.text(errorDescription) }
  }

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
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS moved_folders (path TEXT PRIMARY KEY, t REAL NOT NULL, payload BLOB NOT NULL)"
      )
    }
    return try body(db)
  }

  private func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw Failure(errorDescription: String(cString: sqlite3_errmsg(db)))
    }
  }

  private func decodedRow<T: Decodable>(_ query: OpaquePointer?) -> T? {
    guard let ptr = sqlite3_column_blob(query, 0) else { return nil }
    return try? JSONDecoder().decode(
      T.self, from: Data(bytes: ptr, count: Int(sqlite3_column_bytes(query, 0))))
  }

  func read(limit: Int = 10, retention: ActivityRetention = .forever, at now: Date = .now) throws -> [ScanReport] {
    try connection(write: false) { db in
      var query: OpaquePointer?
      guard
        sqlite3_prepare_v2(db, "SELECT payload FROM scans WHERE t >= ? ORDER BY t DESC", -1, &query, nil)
          == SQLITE_OK
      else { throw Failure(errorDescription: "Geçmiş sorgulanamadı.") }
      defer { sqlite3_finalize(query) }
      sqlite3_bind_double(query, 1, retention.cutoff(at: now)?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
      var rows: [ScanReport] = []
      while rows.count < limit {
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW else {
          throw Failure(errorDescription: "Geçmiş okunamadı.")
        }
        if let row: ScanReport = decodedRow(query) { rows.append(row) }
      }
      return rows
    } ?? []
  }

  func weeklyGrowth(ending report: ScanReport, calendar: Calendar = .current) throws -> WeeklyGrowth
  {
    let today = calendar.startOfDay(for: report.date)
    guard let scope = report.scope else { return WeeklyGrowth(current: report, earlierDays: []) }
    let snapshots: [ScanReport] =
      try connection(write: false) { db in
        var query: OpaquePointer?
        let sql = """
          SELECT payload FROM scans WHERE t >= ? AND t < ?
          AND CASE WHEN json_valid(CAST(payload AS TEXT)) THEN json_extract(CAST(payload AS TEXT),'$.scope') END = ?
          AND CASE WHEN json_valid(CAST(payload AS TEXT)) THEN json_extract(CAST(payload AS TEXT),'$.extended') END = ?
          ORDER BY t DESC
          """
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else {
          throw Failure(errorDescription: "Haftalık ölçümler okunamadı.")
        }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 3, scope, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(query, 4, report.extended ? 1 : 0)
        var rows: [ScanReport] = []
        for day in -6..<0 {
          try Task.checkCancellation()
          guard let start = calendar.date(byAdding: .day, value: day, to: today),
            let end = calendar.date(byAdding: .day, value: 1, to: start)
          else { continue }
          sqlite3_reset(query)
          sqlite3_bind_double(query, 1, start.timeIntervalSince1970)
          sqlite3_bind_double(query, 2, end.timeIntervalSince1970)
          while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
              throw Failure(errorDescription: "Haftalık ölçümler okunamadı.")
            }
            if let row: ScanReport = decodedRow(query) {
              rows.append(row)
              break
            }
          }
        }
        return rows
      } ?? []
    return WeeklyGrowth(current: report, earlierDays: snapshots)
  }

  func save(_ report: ScanReport, retention: ActivityRetention = .forever, at now: Date = .now) throws {
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
        try pruneScans(db, retention: retention, at: now)
        try execute(db, "DELETE FROM moved_folders WHERE t < unixepoch('now','-180 days')")
        try execute(db, "COMMIT")
      } catch {
        try? execute(db, "ROLLBACK")
        throw error
      }
    }
  }

  // Retention affects scan snapshots only. Trash receipts and regrowth evidence are separate.
  func prune(retention: ActivityRetention, at now: Date = .now) throws {
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    _ = try connection(write: true) { db in try pruneScans(db, retention: retention, at: now) }
  }

  private func pruneScans(_ db: OpaquePointer, retention: ActivityRetention, at now: Date) throws {
    guard let cutoff = retention.cutoff(at: now) else { return }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "DELETE FROM scans WHERE t < ?", -1, &statement, nil) == SQLITE_OK
    else { throw Failure(errorDescription: "Geçmiş güncellenemedi.") }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw Failure(errorDescription: "Geçmiş güncellenemedi.")
    }
  }

  func remember(_ folders: [MovedFolder], updatingEvidence: Bool = false) throws {
    guard !folders.isEmpty else { return }
    _ = try connection(write: true) { db in
      try execute(db, "BEGIN IMMEDIATE")
      do {
        var statement: OpaquePointer?
        // Evidence from an in-flight scan cannot revive a restored or superseded receipt.
        let sql =
          updatingEvidence
          ? "UPDATE moved_folders SET payload=?3 WHERE path=?1 AND t=?2 AND json_extract(CAST(payload AS TEXT),'$.receipt.id')=json_extract(CAST(?3 AS TEXT),'$.receipt.id')"
          : "INSERT OR REPLACE INTO moved_folders VALUES (?,?,?)"
        guard
          sqlite3_prepare_v2(
            db, sql, -1, &statement, nil)
            == SQLITE_OK
        else {
          throw Failure(errorDescription: "Temizlik geçmişi yazılamadı.")
        }
        defer { sqlite3_finalize(statement) }
        for folder in folders {
          let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
          let data = try JSONEncoder().encode(folder)
          sqlite3_reset(statement)
          sqlite3_bind_text(statement, 1, folder.receipt.original.path, -1, transient)
          sqlite3_bind_double(statement, 2, folder.receipt.date.timeIntervalSince1970)
          let status = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient)
            return sqlite3_step(statement)
          }
          guard status == SQLITE_DONE else {
            throw Failure(errorDescription: "Temizlik geçmişi yazılamadı.")
          }
        }
        try execute(
          db,
          "DELETE FROM moved_folders WHERE t < unixepoch('now','-180 days') OR path NOT IN (SELECT path FROM moved_folders ORDER BY t DESC LIMIT 400)"
        )
        try execute(db, "COMMIT")
      } catch {
        try? execute(db, "ROLLBACK")
        throw error
      }
    }
  }

  func movedFolders() throws -> [MovedFolder] {
    try connection(write: false) { db in
      // Archives from 0.4.0 contain only scans.
      guard
        sqlite3_table_column_metadata(db, nil, "moved_folders", "path", nil, nil, nil, nil, nil)
          == SQLITE_OK
      else { return [] }
      var query: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          db,
          "SELECT payload FROM moved_folders WHERE t >= unixepoch('now','-180 days') ORDER BY t DESC LIMIT 400",
          -1, &query, nil) == SQLITE_OK
      else { throw Failure(errorDescription: "Temizlik geçmişi okunamadı.") }
      defer { sqlite3_finalize(query) }
      var result: [MovedFolder] = []
      while true {
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return result }
        guard status == SQLITE_ROW else {
          throw Failure(errorDescription: "Temizlik geçmişi okunamadı.")
        }
        if let folder: MovedFolder = decodedRow(query) { result.append(folder) }
      }
    } ?? []
  }

  func forgetMove(at path: String) throws {
    _ = try connection(write: true) { db in
      var query: OpaquePointer?
      guard
        sqlite3_prepare_v2(db, "DELETE FROM moved_folders WHERE path = ?", -1, &query, nil)
          == SQLITE_OK
      else { throw Failure(errorDescription: "Temizlik geçmişi güncellenemedi.") }
      defer { sqlite3_finalize(query) }
      sqlite3_bind_text(query, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      guard sqlite3_step(query) == SQLITE_DONE else {
        throw Failure(errorDescription: "Temizlik geçmişi güncellenemedi.")
      }
    }
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: file.path) {
      _ = try connection(write: true) { db in
        try execute(db, "PRAGMA secure_delete=ON")
        try execute(db, "BEGIN IMMEDIATE")
        do {
          try execute(db, "DELETE FROM scans")
          try execute(db, "DELETE FROM moved_folders")
          try execute(db, "COMMIT")
        } catch {
          try? execute(db, "ROLLBACK")
          throw error
        }
      }
    }
  }
}

actor HistoryIO {
  static let shared = HistoryIO()
  private let archive: ScanArchive
  init(archive: ScanArchive = .standard) { self.archive = archive }

  func load(retention: ActivityRetention = .saved()) throws -> [ScanReport] {
    try archive.read(limit: 35, retention: retention)
  }

  func prune(retention: ActivityRetention) throws { try archive.prune(retention: retention) }
  func weeklyGrowth(ending report: ScanReport) throws -> WeeklyGrowth {
    try archive.weeklyGrowth(ending: report)
  }
  func record(_ report: ScanReport, retention: ActivityRetention = .saved()) throws {
    try archive.save(report, retention: retention)
  }
  func remember(_ folders: [MovedFolder], updatingEvidence: Bool = false) throws {
    try archive.remember(folders, updatingEvidence: updatingEvidence)
  }
  func movedFolders() throws -> [MovedFolder] { try archive.movedFolders() }
  func forgetMove(at path: String) throws { try archive.forgetMove(at: path) }
  func clear() throws { try archive.clear() }
}
