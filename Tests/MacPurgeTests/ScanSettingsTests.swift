import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct ScanSettingsTests {
  private struct Fixture {
    let home = URL(fileURLWithPath: "/private/tmp/macpurge-settings-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
    func folder(_ path: String) throws -> URL {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
    func finish() { try? FileManager.default.removeItem(at: home) }
    func report(at date: Date) -> ScanReport {
      ScanReport(id: UUID(), date: date, extended: false, free: 100, capacity: 1000, items: [])
    }
  }

  @Test func excludedSubtreesAreNotDiscoveredOrMeasuredAndSiblingPrefixesRemainIncluded() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let ignored = try f.folder("project/private")
    let included = try f.folder("project/private-copy")
    try Data(repeating: 7, count: 32768).write(to: ignored.appending(path: "ignored"))
    try Data(repeating: 4, count: 8192).write(to: included.appending(path: "included"))
    let project = ignored.deletingLastPathComponent()
    let root = ScanRoot(group: .projects, title: "project", url: project, profile: .project)
    let policy = ScanExclusions(paths: [ignored.path, ignored.path])
    #expect(policy.paths.count == 1)
    #expect(policy.contains(ignored.appending(path: "deep/secret")))
    #expect(!policy.contains(included))
    let baseline = try await StorageMeter.measure(root)
    try await ScanExclusions.$current.withValue(policy) {
      #expect(try DirectoryIndex.children(of: project).map(\.url) == [included])
      #expect(try DirectoryIndex.children(of: ignored).isEmpty)
      let reading = try await StorageMeter.measure(root)
      #expect(reading.state == .complete && reading.files == 1 && reading.missed == 0)
      #expect(reading.bytes < baseline.bytes)
      #expect(try await StorageMeter.measure(.init(group: .projects, title: "ignored", url: ignored)).state == .absent)
    }
    // The scan's policy cannot leak into later work on the same executor.
    #expect(try await StorageMeter.measure(root).files == 2)
  }

  @MainActor @Test func quickAndDetailedScansPersistExclusionsAndNeverOfferPartialParentsForCleanup() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let cache = try f.folder(".npm/_cacache")
    let ignored = try f.folder(".npm/_cacache/private")
    _ = try f.folder(".Trash")
    try Data(repeating: 4, count: 8192).write(to: cache.appending(path: "included"))
    try Data(repeating: 7, count: 32768).write(to: ignored.appending(path: "ignored"))
    let suite = "macpurge-settings-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set([ignored.path], forKey: ScanExclusions.preference)
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "journal"), packageIdle: { _ in true })
    let scan = LiveScan(defaults: defaults, recordsHistory: false, home: f.home, cleanupEngine: engine,
      localInventory: { _, _, _, _ in [] }, toolInventory: { _, _ in [] })
    #expect(scan.excludedFolders.map(\.path) == [ignored.path])
    var scopes: [String] = []
    for detailed in [false, true] {
      if detailed { scan.startDetailed() } else { scan.startQuick() }
      await scan.finishCurrentScan()
      #expect(scan.phase == .finished)
      let report = try #require(scan.report)
      let row = try #require(report.items.first { $0.path == cache.path })
      #expect(row.containsExcludedFolders == true && row.eligibleBytes == 0)
      #expect(scan.roots.contains { $0.url.path == cache.path && $0.excludedDirectories.contains("private") })
      #expect(!report.items.contains { $0.path == ignored.path })
      #expect(await engine.prepare(items: [row], reportID: report.id, projects: []).targets.isEmpty)
      let decisions = try await engine.actions(for: [row], projects: [], reportID: report.id,
        readings: scan.cleanupReadings, manual: [:], restrictions: [:])
      #expect(decisions[row.id]?.bytes == 0)
      scopes.append(try #require(report.scope))
    }
    scan.removeExcludedFolder(ignored)
    await scan.finishCurrentScan()
    #expect(scan.excludedFolders.isEmpty)
    #expect(ScanExclusions.saved(in: defaults).paths.isEmpty)
    #expect(scan.report?.scope != scopes.last)
    let row = try #require(scan.report?.items.first { $0.path == cache.path })
    #expect(row.containsExcludedFolders != true && row.eligibleBytes > 0)
    scan.addExcludedFolders([ignored, ignored])
    await scan.finishCurrentScan()
    #expect(scan.excludedFolders.map(\.path) == [ignored.path])
    let reopened = LiveScan(defaults: defaults, recordsHistory: false, home: f.home)
    #expect(reopened.excludedFolders.map(\.path) == [ignored.path])
  }

  @Test func retentionUsesAnExactCutoffAndDoesNotRemoveRestoreEvidence() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let archive = ScanArchive(file: f.home.appending(path: "history.sqlite"))
    let now = Date.now
    let cutoff = try #require(ActivityRetention.thirtyDays.cutoff(at: now))
    for date in [cutoff - 1, cutoff, now] { try archive.save(f.report(at: date), retention: .forever) }
    var info = stat()
    info.st_dev = 1
    info.st_ino = 2
    let identity = FileIdentity(info)
    let receipt = TrashReceipt(id: UUID(), original: f.home.appending(path: "cache"),
      parent: identity, identity: identity, bytes: 100, date: now - 40 * 86400)
    let move = MovedFolder(receipt: receipt, itemID: "cache", name: "cache", workspace: nil)
    try archive.remember([move])
    try archive.prune(retention: .thirtyDays, at: now)
    #expect(try archive.read().map(\.date) == [now, cutoff])
    #expect(try archive.movedFolders().first?.receipt.id == receipt.id)
  }

  @Test func foreverKeepsOldRecordsAndReadOnlyLoadsDoNotPrune() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let archive = ScanArchive(file: f.home.appending(path: "history.sqlite"))
    let now = Date.now
    // More than the previous 400-record cap, including records older than 180 days.
    for i in 0..<405 { try archive.save(f.report(at: now - Double(i) * 86400), retention: .forever) }
    #expect(try archive.read(limit: 1000).count == 405)
    let io = HistoryIO(archive: archive)
    #expect(try await io.load(retention: .thirtyDays).count <= 31)
    #expect(try archive.read(limit: 1000).count == 405)
    try archive.prune(retention: .ninetyDays, at: now)
    #expect(try archive.read(limit: 1000).count == 91)
    try archive.prune(retention: .forever, at: now)
    #expect(try archive.read(limit: 1000).count == 91)
  }
}
