import Darwin
import Foundation
import SQLite3
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct ScanRegressionTests {
  private struct Fixture {
    let home = URL(filePath: "/private/tmp/macpurge-audit-" + UUID().uuidString)
    init() throws {
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func finish() { try? FileManager.default.removeItem(at: home) }
    func folder(_ path: String) throws -> URL {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
  }

  @Test func fullScanReleasesInodeTableAndInternalLinksRemainMovable() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let cache = try f.folder(".npm/_cacache")
    let file = cache.appending(path: "a")
    try Data(repeating: 7, count: 16384).write(to: file)
    try FileManager.default.linkItem(at: file, to: cache.appending(path: "b"))
    let root = ScanRoot(group: .packages, title: "npm", url: cache, profile: .npmCache)
    let size = try await StorageMeter.measure(root)
    #expect(size.links.count == 1 && size.sharedLinkBytes == 0)
    _ = try await StorageMeter.scan([root]) { _ in
    } onFinish: { _, row, total in
      #expect(row.links.isEmpty && row.linkChecks.isEmpty)
      #expect(total == size.bytes && row.files == 1)
    }
    _ = try f.folder(".Trash")
    let engine = CacheTrash(
      home: f.home, journal: f.home.appending(path: "journal"), packageIdle: { _ in true })
    let report = ScanReport.make(
      roots: [root], results: [root.id: size], disk: nil,
      extended: false, homeDevice: size.measuredDevice)
    #expect(report.items.first?.eligibleBytes == size.bytes)
    #expect(
      await engine.prepare(items: report.items, reportID: report.id, projects: []).targets.count
        == 1)
    try FileManager.default.linkItem(at: file, to: f.home.appending(path: "outside"))
    let external = try await StorageMeter.measure(root)
    #expect(external.sharedLinkBytes == size.bytes)
    #expect(
      await engine.prepare(items: report.items, reportID: report.id, projects: []).targets.isEmpty)
  }

  @Test func selectingSystemRootDoesNotChangeAutomaticVolumeOrProjectChildVolume() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let system = URL(filePath: "/")
    let volumes = ScanVolumes(home: f.home, projects: [system])
    let npm = try f.folder(".npm/_cacache")
    var data = stat()
    var boot = stat()
    try #require(stat(npm.path, &data) == 0 && stat("/", &boot) == 0)
    #expect(volumes.device(for: npm) == data.st_dev)
    #expect(
      volumes.restrict(.init(group: .packages, title: "npm", url: npm)).expectedDevice
        == data.st_dev)
    #expect(
      volumes.restrict(.init(group: .projects, title: "System", url: system)).expectedDevice
        == boot.st_dev)
    var discovered = ScanRoot(group: .other, title: "selected child", url: npm)
    discovered.expectedDevice = 777
    #expect(volumes.restrict(discovered).expectedDevice == 777)
  }

  @Test func xcodeWorkspaceDiscoveryRespectsHomeAndExplicitProjects() throws {
    let f = try Fixture()
    defer { f.finish() }
    let derived = try f.folder("Derived")
    let selected = try f.folder("Selected")
    let elsewhere = try f.folder("Elsewhere/App.xcodeproj")
    try Data().write(to: elsewhere.appending(path: "project.pbxproj"))
    try PropertyListEncoder().encode(["WorkspacePath": elsewhere.path]).write(
      to: derived.appending(path: "info.plist"))
    #expect(ProjectAttribution.outputWorkspace(in: derived, home: selected, projects: []) == nil)
    #expect(ProjectAttribution.outputWorkspace(in: derived, home: selected, projects: [f.home])?.path == elsewhere.path)
    #expect(ProjectAttribution.outputWorkspace(in: derived, home: f.home, projects: [])?.profile == .xcodeIntermediate)
  }

  @Test func malformedRowsDoNotHideValidHistoryOrWeeklySamples() throws {
    let f = try Fixture()
    defer { f.finish() }
    let archive = ScanArchive(file: f.home.appending(path: "history.sqlite"))
    let today = Date.now
    let yesterday = Calendar.current.startOfDay(for: today).addingTimeInterval(-3600)
    func report(_ date: Date) -> ScanReport {
      ScanReport(
        id: UUID(), date: date, extended: false, free: nil, capacity: nil, items: [], scope: "s")
    }
    let old = report(yesterday)
    let current = report(today)
    try archive.save(old)
    try archive.save(current)
    var info = stat()
    try #require(stat(f.home.path, &info) == 0)
    let receipt = TrashReceipt(
      id: UUID(), original: f.home, parent: FileIdentity(info), identity: FileIdentity(info),
      bytes: 10, date: yesterday)
    try archive.remember([
      MovedFolder(receipt: receipt, itemID: "cache", name: "cache", workspace: nil)
    ])
    var db: OpaquePointer?
    try #require(sqlite3_open(archive.file.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = """
      INSERT INTO scans VALUES (\(yesterday.timeIntervalSince1970 + 1), X'7B');
      INSERT INTO scans VALUES (\(yesterday.timeIntervalSince1970 + 2), '{"scope":"s","extended":false}');
      INSERT INTO moved_folders VALUES ('broken', \(today.timeIntervalSince1970), X'7B');
      """
    try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    #expect(try archive.read(limit: 2).map(\.id) == [current.id, old.id])
    #expect(try archive.movedFolders().map(\.receipt.id) == [receipt.id])
    #expect(try archive.weeklyGrowth(ending: current).measuredDays == 2)
  }

  @Test func hardLinksRemainReusableOnlyWithUnchangedInodeAndTree() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let nested = try f.folder("project/nested")
    let project = nested.deletingLastPathComponent()
    let file = nested.appending(path: "inside")
    let alias = f.home.appending(path: "external")
    try Data(repeating: 1, count: 8192).write(to: file)
    try FileManager.default.linkItem(at: file, to: alias)
    let root = ScanRoot(group: .projects, title: "project", url: project)
    let cache = MeasurementCache()
    await cache.configure([root])
    let before = await cache.ticket(root)
    let row = try await StorageMeter.measure(root, trackLinks: true)
    let (key, check) = try #require(row.linkChecks.first)
    let dir = open(project.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try #require(dir >= 0)
    defer { close(dir) }
    #expect(check.matches(key, in: dir))
    await cache.store(row, for: root, before: before)
    let hit = await cache.cached(root, await cache.ticket(root))
    if before == nil { #expect(hit == nil) } else { #expect(hit?.bytes == row.bytes) }

    let writer = try FileHandle(forWritingTo: alias)
    try writer.write(contentsOf: Data(repeating: 3, count: 128 * 1024))
    try writer.close()
    #expect(!check.matches(key, in: dir))
    #expect(await cache.cached(root, await cache.ticket(root)) == nil)
    #expect(try await StorageMeter.measure(root).bytes > row.bytes)
  }

  @Test func projectLinksDoNotForceAnotherWalkOfEverySmallChild() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let a = try f.folder("A")
    let b = try f.folder("B")
    _ = try f.folder("small")
    let file = a.appending(path: "file")
    try Data(repeating: 5, count: 16384).write(to: file)
    try FileManager.default.linkItem(at: file, to: b.appending(path: "same"))
    var measured = try await StorageMeter.measure(
      .init(group: .projects, title: "project", url: f.home))
    #expect(measured.files == 1)
    let limit: Int64 = 500 * 1024 * 1024
    let bytes = measured.bytes
    // Model large branches with one allocation shared by both, without allocating 500 MB in a unit test.
    for name in ["A", "B"] {
      #expect(
        measured.largest[name, default: 0] + measured.duplicateBytesByBranch[name, default: 0]
          == bytes)
      measured.largest[name, default: 0] += limit - bytes
    }
    measured.sharedLinkBytes = bytes
    let rows = try CategoryLocations.largeFolders(in: f.home, excluding: [], measurement: measured)
    #expect(Set(rows.map(\.title)) == ["A", "B"])
  }

  @Test func automaticDiscoveryAndMeasurementStopAtForeignDevices() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let child = try f.folder("child")
    let file = child.appending(path: "data")
    try Data(repeating: 1, count: 8192).write(to: file)
    let volumes = await ScanVolumes.read(home: f.home, projects: [child])
    var root = volumes.restrict(.init(group: .projects, title: "project", url: child))
    let device = try #require(root.expectedDevice)
    #expect(
      try DirectoryIndex.children(of: f.home, onDevice: device).map(\.url.path) == [child.path])
    #expect(try await StorageMeter.measure(root).bytes > 0)
    let foreign = device &+ 1
    do {
      _ = try DirectoryIndex.children(of: f.home, onDevice: foreign)
      Issue.record("Enumerated a root on a different device")
    } catch let failure as DirectoryIndex.Problem { #expect(failure.code == EXDEV) }
    root.expectedDevice = foreign
    #expect(try await StorageMeter.measure(root).state == .unavailable("Farklı disk"))
    var fileRoot = ScanRoot(group: .shared, title: "file", url: file, source: .file)
    fileRoot.expectedDevice = foreign
    #expect(try await StorageMeter.measure(fileRoot).state == .unavailable("Farklı disk"))
    let cache = MeasurementCache()
    await cache.configure([root])
    #expect(await cache.ticket(root) == nil)
    let deviceSet = try await SimulatorInventory.discover(in: f.home, onDevice: foreign)
    #expect(deviceSet.roots.isEmpty && deviceSet.note != nil)
    // Real mount points, when present on this Mac; nothing is mounted or detached by the test.
    let mounts = URL(filePath: "/System/Volumes")
    if let entries = try? DirectoryIndex.children(of: mounts) {
      var parent = stat()
      if stat(mounts.path, &parent) == 0 {
        #expect(entries.allSatisfy { $0.device == parent.st_dev })
      }
    }
  }

  @Test func reportBreakdownKeepsDeterministicTopFive() {
    var reading = RootSize(
      largest: Dictionary(
        uniqueKeysWithValues: (0..<20_000).map {
          (String($0), Int64($0 % 11))
        }))
    let expected = reading.largest.sorted {
      $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
    }.prefix(5).map(\.key)
    reading.finishBreakdown()
    #expect(reading.largestFive.map(\.key) == expected)
    let root = ScanRoot(group: .models, title: "fixture", url: URL(filePath: "/test"))
    let report = ScanReport.make(
      roots: [root], results: [root.id: reading], disk: nil, extended: true, homeDevice: nil)
    #expect(Set(report.items.first?.parts.keys.map { $0 } ?? []) == Set(expected))
  }

  private actor ToolGate {
    private var released = false
    func open() { released = true }
    func wait() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !released {
        guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
        try await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  @MainActor @Test func slowToolDoesNotBlockLocalCategoriesAndCancelRestoresOnlyMatchingScope()
    async throws
  {
    let f = try Fixture()
    defer { f.finish() }
    let suite = UUID().uuidString
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.set(false, forKey: "keepsScanArchive")
    let gate = ToolGate()
    let scan = LiveScan(
      defaults: prefs, home: f.home,
      localInventory: { home, _, _, _ in
        [
          .init(
            group: .models, title: "local", url: home.appending(path: "local"),
            source: .allocation(17))
        ]
      },
      toolInventory: { home, _ in
        try await gate.wait()
        return [
          .init(
            group: .runtimes, title: "tool", url: home.appending(path: "tool"), source: .report(31))
        ]
      })
    scan.startDetailed()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while scan.storageReport?.groups?[ScanGroup.models.rawValue] != 17
      && ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(scan.phase == .running && scan.pendingCategories.contains(.runtimes))
    #expect(scan.storageReport?.items.map(\.name) == ["local"])
    await gate.open()
    await scan.finishCurrentScan()
    let done = try #require(scan.storageReport)
    #expect(scan.phase == .finished)
    #expect(done.items.map(\.name) == ["tool", "local"])
    #expect(
      done.groups?[ScanGroup.models.rawValue] == 17
        && done.groups?[ScanGroup.runtimes.rawValue] == 31)
    scan.startDetailed()
    #expect(scan.storageReport?.id == done.id)
    scan.cancel()
    #expect(scan.storageReport?.id == done.id)
    scan.startQuick()
    #expect(scan.storageReport == nil)
    scan.cancel()
    await scan.finishCurrentScan()
    #expect(scan.phase == .cancelled && scan.storageReport == nil)
    let selected = try f.folder("new-project")
    scan.addProjects([selected])
    scan.cancel()
    await scan.finishCurrentScan()
    #expect(scan.storageReport == nil)
  }
}
