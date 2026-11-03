import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct StorageInsightsTests {
  @Test func downloadBucketsExcludeSiblingsAndUndoRestoresOnlyVerifiedDownloads() async throws {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/private/tmp/MacPurge-Downloads-" + UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    func write(_ path: String, value: UInt8) throws {
      let url = home.appending(path: path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: value, count: 16384).write(to: url)
    }
    let file = String(repeating: "e", count: 56)
    let bottle = String(repeating: "a", count: 64) + "--release.tar.gz"
    let pipFile = PackageDownloadCache.pip.rawValue + "/e/e/e/e/e/" + file + ".body"
    let brewFile = PackageDownloadCache.brew.rawValue + "/" + bottle
    try write(pipFile, value: 1)
    try write(brewFile, value: 2)
    let wheel = "Library/Caches/pip/wheels/local.whl"
    let other = "Library/Caches/Homebrew/api/config"
    try write(wheel, value: 3)
    try write(other, value: 4)
    try fm.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
    let roots = ScanRoot.catalog(home: home, projects: []).filter {
      $0.downloadCache != nil || !$0.excludedDirectories.isEmpty
    }
    func scan() async throws -> ScanReport {
      var results: [String: RootSize] = [:]
      for root in roots { results[root.id] = try await StorageMeter.measure(root) }
      let dev = try TrashFiles.directory(home) { _, info in info.st_dev }
      return .make(roots: roots, results: results, disk: nil, extended: false, homeDevice: dev)
    }
    let report = try await scan()
    let safe = report.items.filter { $0.safety == SafetyLevel.safe.rawValue }
    #expect(
      Set(safe.map(\.path))
        == Set([PackageDownloadCache.pip, .brew].map { home.appending(path: $0.rawValue).path }))
    let splitBytes = report.items.compactMap(\.bytes).reduce(0, +)
    var actualBytes: Int64 = 0
    for path in [pipFile, brewFile, wheel, other] {
      var statInfo = stat()
      #expect(lstat(home.appending(path: path).path, &statInfo) == 0)
      actualBytes += Int64(statInfo.st_blocks) * 512
    }
    #expect(splitBytes == actualBytes)
    let busy = CacheTrash(
      home: home, journal: home.appending(path: "receipts"), packageIdle: { _ in false })
    #expect(await busy.prepare(items: safe, reportID: report.id, projects: []).targets.isEmpty)
    let engine = CacheTrash(
      home: home, journal: home.appending(path: "receipts"), packageIdle: { _ in true })
    let plan = await engine.prepare(items: report.items, reportID: report.id, projects: [])
    #expect(plan.targets.count == 2)
    #expect(await busy.apply(plan).moved.isEmpty)
    let incomplete = PackageDownloadCache.brew.rawValue + "/" + bottle + ".incomplete"
    try write(incomplete, value: 8)
    let mixed = try await scan()
    #expect(
      mixed.items.first { $0.path.hasSuffix("/Homebrew/downloads") }?.safety
        == SafetyLevel.review.rawValue)
    // Even a stale/forged Safe report cannot bypass the live payload validation.
    #expect(await engine.prepare(items: safe, reportID: report.id, projects: []).targets.count == 1)
    let changed = await engine.apply(plan)
    #expect(changed.moved.count == 1 && changed.moved[0].original.path.hasSuffix("/pip/http-v2"))
    try await engine.restore(try #require(changed.moved.first).id)
    try fm.removeItem(at: home.appending(path: incomplete))
    let result = await engine.apply(engine.prepare(items: safe, reportID: report.id, projects: []))
    #expect(result.moved.count == 2)
    #expect(!fm.fileExists(atPath: home.appending(path: brewFile).path))
    #expect(!fm.fileExists(atPath: home.appending(path: pipFile).path))
    #expect(try Data(contentsOf: home.appending(path: wheel)).first == 3)
    #expect(try Data(contentsOf: home.appending(path: other)).first == 4)
    for receipt in result.moved { try await engine.restore(receipt.id) }
    #expect(try Data(contentsOf: home.appending(path: brewFile)).first == 2)
    #expect(try Data(contentsOf: home.appending(path: pipFile)).first == 1)
    try write(PackageDownloadCache.pip.rawValue + "/personal", value: 5)
    #expect(try await scan().items.first { $0.path.hasSuffix("/pip/http-v2") }?.eligibleBytes == 0)
  }

  @Test func ageBucketsUseMtimeCountEachInodeOnceAndAdvanceWithoutChanges() async throws {
    let fm = FileManager.default
    let folder = URL(fileURLWithPath: "/private/tmp/MacPurge-FileAge-" + UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func write(_ name: String, secondsAgo: Double) throws -> Int64 {
      let file = folder.appending(path: name)
      try Data(repeating: 30, count: 16384).write(to: file)
      try fm.setAttributes(
        [.modificationDate: now.addingTimeInterval(-secondsAgo)], ofItemAtPath: file.path)
      var info = stat()
      #expect(lstat(file.path, &info) == 0)
      return Int64(info.st_blocks) * 512
    }
    let cutoff = 72.0 * 3600
    let boundary = try write("boundary", secondsAgo: cutoff)
    let old = try write("old", secondsAgo: cutoff + 1)
    try fm.linkItem(at: folder.appending(path: "old"), to: folder.appending(path: "old-link"))
    try fm.createSymbolicLink(
      at: folder.appending(path: "alias"), withDestinationURL: folder.appending(path: "boundary"))
    let root = ScanRoot(group: .temp, title: "Temporary", url: folder, profile: .systemManaged)
    let measure = try await StorageMeter.measure(root, at: now)
    #expect(measure.files == 2 && measure.age == FileAgeBreakdown(recent: boundary, older: old))
    #expect(measure.bytes == old + boundary)
    let later = try await StorageMeter.measure(root, at: now.addingTimeInterval(1))
    #expect(later.age == FileAgeBreakdown(recent: 0, older: old + boundary))
    let cache = MeasurementCache()
    await cache.configure([root])
    #expect(await cache.ticket(root) == nil)
    let snapshot = ScanReport.make(
      roots: [root], results: [root.id: measure], disk: nil, extended: true,
      homeDevice: measure.measuredDevice)
    let saved = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(snapshot))
    #expect(saved.items.first?.age == measure.age && saved.items.first?.eligibleBytes == 0)
  }

  @Test func weeklyHistoryUsesDistinctDaysMatchingScopeAndComparableFolders() throws {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: "/private/tmp/MacPurge-Week-" + UUID().uuidString)
    defer { try? fm.removeItem(at: dir) }
    let archive = ScanArchive(file: dir.appending(path: "history.sqlite"))
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    func day(_ offset: Int, _ minute: Int = 0) throws -> Date {
      let date = try #require(calendar.date(byAdding: .day, value: offset, to: today))
      return date.addingTimeInterval(Double(minute * 60))
    }
    func row(_ id: String, _ bytes: Int64, volume: Int32 = 1) -> ReportItem {
      ReportItem(
        id: id, name: id, category: "Packages", path: "/cache/" + id,
        bytes: bytes, status: "complete", safety: "İncele", reason: "", basis: "allocated",
        eligibleBytes: 0,
        modified: nil, parts: [:], volume: volume, directoryInode: 3)
    }
    func scan(_ date: Date, _ size: Int64, _ scope: String = "one", _ rows: [ReportItem] = [])
      -> ScanReport
    {
      .init(
        id: UUID(), date: date, extended: true, free: nil, capacity: nil, items: rows,
        groups: ["Packages": size, "Unchanged": 20], scope: scope)
    }
    let baseline = scan(try day(-6, 900), 100, "one", [row("A", 30), row("moved", 4)])
    let current = scan(
      try day(0), 180, "one", [row("A", 50), row("new", 10), row("moved", 90, volume: 2)])
    #expect(try archive.weeklyGrowth(ending: current).measuredDays == 1)
    for record in [
      scan(try day(-7), 1), scan(try day(-6), 5), baseline, scan(try day(-6, 910), 900, "other"),
    ] {
      try archive.save(record)
    }
    // The normal UI loads the last 35 scans. One busy day must not push the baseline out of the week.
    for i in 0..<40 { try archive.save(scan(try day(-1, i), 120 + Int64(i))) }
    try archive.save(current)
    let result = try archive.weeklyGrowth(ending: current)
    #expect(result.measuredDays == 3 && result.start == baseline.date)
    let group = try #require(result.categories.first)
    #expect(
      group.name == "Packages" && group.change == 80
        && group.samples.map(\.bytes) == [100, 159, 180])
    #expect(group.folders.map(\.item.id) == ["A", "new"])
    #expect(group.folders.map(\.firstSeen) == [false, true])
    let partial = ScanReport(
      id: UUID(), date: current.date, extended: true, free: nil, capacity: nil, items: [],
      groups: [:], scope: "one")
    #expect(try archive.weeklyGrowth(ending: partial).comparableCategories == 0)
  }
}
