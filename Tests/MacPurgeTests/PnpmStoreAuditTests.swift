import Darwin
import Foundation
import SQLite3
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct PnpmStoreAuditTests {
  @Test func keepsSharedBlobsAndReportsBothStoreVersionsReadOnly() async throws {
    let fixture = URL(filePath: "/private/tmp/MacPurge-pnpm-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let store = fixture.appending(path: "store")
    let project = fixture.appending(path: "project")
    let registered = fixture.appending(path: "registered")
    let lock = """
      lockfileVersion: '9.0'
      packages:
        used@1.0.0: {}
      """
    func write(_ data: Data, at url: URL) throws {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
    try write(Data(lock.utf8), at: project.appending(path: "pnpm-lock.yaml"))
    try write(Data(lock.utf8), at: registered.appending(path: "node_modules/.pnpm/lock.yaml"))
    let registry = store.appending(path: "v10/projects")
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: registry.appending(path: "project"), withDestinationURL: registered)

    let unmatched = String(repeating: "a", count: 128)
    let shared = String(repeating: "b", count: 128)
    let orphan = String(repeating: "c", count: 128)
    let source = "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()
    func blob(_ digest: String, version: String) throws -> Int64 {
      let url = store.appending(path: version + "/files/" + digest.prefix(2) + "/" + digest.dropFirst(2))
      try write(Data(repeating: 5, count: 16384), at: url)
      var info = stat()
      try #require(lstat(url.path, &info) == 0)
      return Int64(info.st_blocks) * 512
    }
    let v10Bytes = try blob(unmatched, version: "v10")
    _ = try blob(shared, version: "v10")
    _ = try blob(orphan, version: "v10")
    let v11Bytes = try blob(unmatched, version: "v11")
    _ = try blob(shared, version: "v11")

    func v10Index(_ name: String, digests: [String]) throws {
      let files = Dictionary(uniqueKeysWithValues: digests.map { ($0, ["digest": $0, "mode": 420] as [String: Any]) })
      let data = try JSONSerialization.data(withJSONObject: ["name": name, "version": "1.0.0", "files": files])
      let stem = String(repeating: "0", count: 62)
      try write(data, at: store.appending(path: "v10/index/00/\(stem)-\(name)@1.0.0.json"))
    }
    try v10Index("old", digests: [unmatched, shared])
    try v10Index("used", digests: [shared])

    // Inline msgpackr record with one "files" key and a map of content entries.
    func indexRecord(_ digests: [String]) -> String {
      var bytes: [UInt8] = [0xd4, 0x72, 0x40, 0x91, 0xa5] + Array("files".utf8)
      bytes.append(0x80 | UInt8(digests.count))
      for (i, digest) in digests.enumerated() {
        bytes += [0xa1, UInt8(0x61 + i), 0x82, 0xa6] + Array("digest".utf8)
        bytes += [0xd9, 128] + Array(digest.utf8)
        bytes += [0xa4] + Array("mode".utf8) + [0xcd, 0x01, 0xa4]
      }
      return bytes.map { String(format: "%02x", $0) }.joined()
    }
    let database = store.appending(path: "v11/index.db")
    var db: OpaquePointer?
    try #require(sqlite3_open(database.path, &db) == SQLITE_OK)
    let sql = """
      CREATE TABLE package_index(key TEXT PRIMARY KEY, data BLOB);
      INSERT INTO package_index VALUES ('\(source)\told@1.0.0', X'\(indexRecord([unmatched, shared]))');
      INSERT INTO package_index VALUES ('\(source)\tused@1.0.0', X'\(indexRecord([shared]))');
      """
    let status = sqlite3_exec(db, sql, nil, nil, nil)
    sqlite3_close(db)
    try #require(status == SQLITE_OK)
    let before = try Data(contentsOf: database)

    let result = try await PnpmStoreAudit.read(store: store, projects: [project], exclusions: .init(paths: []))
    #expect(result.versions.first { $0.id == "v10" }?.unmatchedBytes == v10Bytes)
    #expect(result.versions.first { $0.id == "v11" }?.unmatchedBytes == v11Bytes)
    #expect(result.unmatchedBytes == v10Bytes + v11Bytes)
    #expect(result.projectScopes == 1 && result.registeredProjects == 1)
    #expect(result.wantedLocks == 1 && result.installedLocks == 1 && !result.incomplete)
    #expect(try Data(contentsOf: database) == before)
    #expect(!FileManager.default.fileExists(atPath: database.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: database.path + "-shm"))
  }
}
