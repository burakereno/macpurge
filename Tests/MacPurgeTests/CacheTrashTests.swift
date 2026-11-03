import Darwin
import Foundation
import Testing

@testable import MacPurge

struct CacheTrashTests {
  private struct Fixture {
    let home = URL(fileURLWithPath: "/private/tmp")
      .appending(path: "MacPurge-TrashTest-" + UUID().uuidString)
    var bin: URL { home.appending(path: ".Trash") }
    var journal: URL { home.appending(path: "receipts") }
    var npm: URL { home.appending(path: ".npm/_cacache") }
    var go: URL { home.appending(path: "Library/Caches/go-build") }
    func store(shutdown: Bool = true) -> CacheTrash {
      CacheTrash(home: home, journal: journal, deviceIsShutdown: { _ in shutdown })
    }
    init() throws {
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }
    func finish() { try? FileManager.default.removeItem(at: home) }
    func write(_ url: URL, _ value: UInt8 = 1) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data(repeating: value, count: 16384).write(to: url.appending(path: "payload"))
    }
    func row(
      _ url: URL, category: String = "Paket önbellekleri", safety: String = "Güvenli",
      status: String = "complete"
    ) throws -> ReportItem {
      let dev = try TrashFiles.directory(home) { _, s in s.st_dev }
      return ReportItem(
        id: url.path, name: url.lastPathComponent, category: category,
        path: url.path, bytes: 16384, status: status, safety: safety, reason: "",
        basis: "allocated",
        eligibleBytes: 16384, modified: nil, parts: [:], volume: dev)
    }
  }

  @Test func reversibleBatchReopensAndRefusesToOverwriteNewData() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    try f.write(f.go, 2)
    let engine = f.store()
    let plan = await engine.prepare(
      items: try [f.row(f.npm), f.row(f.go)],
      reportID: UUID(), projects: [])
    #expect(plan.targets.count == 2)
    #expect(FileManager.default.fileExists(atPath: f.npm.path))
    let result = await engine.apply(plan)
    #expect(result.notices.isEmpty)
    #expect(result.moved.count == 2)
    let reopened = f.store()
    let receipts = try await reopened.available()
    #expect(receipts.count == 2)
    let npm = try #require(receipts.first { $0.original.path == f.npm.path })
    try f.write(f.npm, 7)
    await #expect(throws: (any Error).self) { try await reopened.restore(npm.id) }
    #expect(try Data(contentsOf: f.npm.appending(path: "payload")).first == 7)
    try FileManager.default.moveItem(at: f.npm, to: f.home.appending(path: "new-cache"))
    for receipt in receipts { try await reopened.restore(receipt.id) }
    #expect(try Data(contentsOf: f.npm.appending(path: "payload")).first == 1)
    #expect(try Data(contentsOf: f.go.appending(path: "payload")).first == 2)
    #expect(try await reopened.available().isEmpty)
  }

  @Test func changedContentsAndSymlinkAncestorsAreSkippedIndependently() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    try f.write(f.go)
    let engine = f.store()
    let rows = try [f.row(f.npm), f.row(f.go)]
    let plan = await engine.prepare(items: rows, reportID: UUID(), projects: [])
    try Data(repeating: 9, count: 16384).write(to: f.go.appending(path: "payload"))
    let result = await engine.apply(plan)
    #expect(result.moved.count == 1 && result.notices.count == 1)
    #expect(FileManager.default.fileExists(atPath: f.go.path))
    let next = await engine.prepare(items: [rows[1]], reportID: UUID(), projects: [])
    let parent = f.go.deletingLastPathComponent()
    let relocated = f.home.appending(path: "relocated")
    try FileManager.default.moveItem(at: parent, to: relocated)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: relocated)
    #expect(await engine.apply(next).moved.isEmpty)
    #expect(try Data(contentsOf: relocated.appending(path: "go-build/payload")).first == 9)
  }

  @Test func onlyShutdownDeviceCacheBoundariesCanMove() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let device = f.home.appending(
      path: "Library/Developer/CoreSimulator/Devices/" + UUID().uuidString)
    let sandbox = device.appending(path: "data/Containers/Data/Application/" + UUID().uuidString)
    let cache = sandbox.appending(path: "Library/Caches")
    let personal = sandbox.appending(path: "Documents/Caches")
    try f.write(cache)
    try f.write(personal)
    let row = try f.row(device, category: "Simülatör cihazları")
    let inactive = f.store()
    let plan = await inactive.prepare(items: [row], reportID: UUID(), projects: [])
    #expect(plan.targets.map(\.path.path) == [cache.path])
    let active = f.store(shutdown: false)
    #expect(await active.prepare(items: [row], reportID: UUID(), projects: []).targets.isEmpty)
    #expect(await active.apply(plan).moved.isEmpty)
    #expect(await inactive.apply(plan).moved.count == 1)
    #expect(FileManager.default.fileExists(atPath: personal.appending(path: "payload").path))
  }

  @Test func refuseUntrustedReportRowsAndMissingTrash() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    let engine = f.store()
    let wrong = try [
      f.row(f.home), f.row(f.npm, safety: "İncele"),
      f.row(f.npm, status: "partial"), f.row(f.npm, category: "Seçili proje klasörleri"),
    ]
    #expect(await engine.prepare(items: wrong, reportID: UUID(), projects: []).targets.isEmpty)
    let good = try f.row(f.npm)
    #expect(
      await engine.prepare(items: [good], reportID: UUID(), projects: [f.npm]).targets.isEmpty)
    let plan = await engine.prepare(items: [good], reportID: UUID(), projects: [])
    try FileManager.default.moveItem(at: f.bin, to: f.home.appending(path: "offline-trash"))
    let denied = await engine.apply(plan)
    #expect(denied.moved.isEmpty && !denied.notices.isEmpty)
    #expect(FileManager.default.fileExists(atPath: f.npm.path))
  }

  @Test func cacheSharingAnInodeWithUserDataIsNotOffered() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    let personal = f.home.appending(path: "personal")
    try FileManager.default.linkItem(at: f.npm.appending(path: "payload"), to: personal)
    let engine = f.store()
    let plan = await engine.prepare(items: [try f.row(f.npm)], reportID: UUID(), projects: [])
    #expect(plan.targets.isEmpty && plan.skipped.count == 1)
    #expect(try Data(contentsOf: personal).count == 16384)
  }
}
