import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

@MainActor
struct CleanupMeasurementTests {
  private actor Probe {
    var discovery = 0
    var tools = 0
    var disk = 0
    var onNextDiskRead: (@Sendable () async -> Void)?
    func whenReading(_ action: @escaping @Sendable () async -> Void) { onNextDiskRead = action }
    var observedFree: Int64?
    func observe(_ reading: VolumeReading?) -> VolumeReading? {
      observedFree = reading?.free
      return reading
    }
    func local() { discovery += 1 }
    func external() { tools += 1 }
    func reading() async -> VolumeReading {
      let action = onNextDiskRead
      onNextDiskRead = nil
      await action?()
      disk += 1
      return VolumeReading(name: "Test disk", bytes: 20_000_000, free: 4_000_000 - Int64(13 * disk))
    }
  }

  @MainActor private struct Fixture {
    let home = URL(filePath: "/private/tmp/MacPurge-Targeted-" + UUID().uuidString)
    let suite = UUID().uuidString
    let probe = Probe()
    let prefs: UserDefaults
    init() throws {
      prefs = try #require(UserDefaults(suiteName: suite))
      prefs.set(false, forKey: "keepsScanArchive")
      try FileManager.default.createDirectory(
        at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
    }
    func finish() {
      prefs.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: home)
    }
    @discardableResult func write(_ relative: String, _ bytes: Int = 16384) throws -> URL {
      let url = home.appending(path: relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 5, count: bytes).write(to: url)
      return url
    }
    func scan(
      project: URL? = nil, device: UUID? = nil, realVolume: Bool = false, extras: [ScanRoot] = [],
      simulatorEngine: CacheTrash? = nil,
      eraseSystemLogs: @escaping @Sendable () async throws -> Void = { throw CancellationError() },
      packageIdle: @escaping @Sendable (PackageTool) async throws -> Bool = { _ in true }
    ) async -> LiveScan {
      if let project { prefs.set([project.path], forKey: "liveScan.selectedProjectPaths") }
      let probe = self.probe
      let engine = simulatorEngine ?? CacheTrash(
        home: home, journal: home.appending(path: "journal"),
        simulatorStates: { device.map { [$0: SimulatorState(state: "Shutdown")] } ?? [:] },
        xcodeIdle: { true }, packageIdle: packageIdle,
        readVolume: { url in
          if realVolume { return await probe.observe(VolumeReading.read(at: url)) }
          return await probe.reading()
        })
      let scan = LiveScan(
        defaults: prefs, home: home, cleanupEngine: engine, eraseSystemLogs: eraseSystemLogs,
        localInventory: { home, _, _, _ in
          await probe.local()
          return [.init(group: .trash, title: "Trash", url: home.appending(path: ".Trash"))]
            + extras
        },
        toolInventory: { _, _ in
          await probe.external()
          return []
        })
      scan.startDetailed()
      await scan.finishCurrentScan()
      await scan.refreshMoveStates()
      return scan
    }
  }

  private func move(_ rows: [ReportItem], scan: LiveScan, onlyPath: URL? = nil) async throws
    -> [TrashReceipt]
  {
    scan.cleanup.prepare(rows, scan: scan, onlyPath: onlyPath)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(scan.cleanup.receipts.isEmpty)
    scan.cleanup.confirmMove(plan.id, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    return try #require(scan.cleanup.outcome).moved
  }

  @Test func npxReviewCannotMoveAnActiveCache() async throws {
    actor Tool {
      var active: URL?
      func use(_ entry: URL?) { active = entry }
      func snapshot() throws -> DevelopmentCacheUse {
        let user = getuid()
        let server = "100 1 \(user) node /test/astro dev"
        let commands = server + "\n101 1 \(user) npm exec fixture"
        let child = active.map { "\n102 101 \(user) node \($0.path)/node_modules/pkg/main.js" } ?? ""
        return try DevelopmentCacheUse(
          processList: active == nil ? server : commands + child,
          openFiles: "p100\nn/private/tmp",
          environmentList: active == nil ? server :
            server + " npm_execpath=/test/npm-cli.js\n101 1 \(user) npm exec fixture" + child
              + " npm_execpath=/test/npm-cli.js",
          npxRoot: active?.deletingLastPathComponent() ?? URL(filePath: "/unused"))
      }
    }
    let f = try Fixture()
    defer { f.finish() }
    func entry(_ key: String, days: Double) throws -> URL {
      let base = ".npm/_npx/\(key)"
      try f.write(base + "/node_modules/pkg/main.js")
      let manifest = try f.write(base + "/package.json")
      try Data(#"{"dependencies":{"pkg":"^1.0.0"}}"#.utf8).write(to: manifest)
      let lock = try f.write(base + "/package-lock.json")
      try Data(#"{"packages":{"":{},"node_modules/pkg":{"resolved":"https://registry.npmjs.org/pkg/-/pkg-1.0.0.tgz"}}}"#.utf8).write(to: lock)
      let url = f.home.appending(path: base)
      for path in [url, manifest, lock, url.appending(path: "node_modules")] {
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86_400)],
          ofItemAtPath: path.path)
      }
      return url
    }
    let active = try entry("0123456789abcdef", days: 45)
    let unused = try entry("0123456789abcdee", days: 45)
    let recent = try entry("0123456789abcdec", days: 1)
    let tool = Tool()
    await tool.use(active)
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "journal"),
      simulatorStates: { [:] }, developmentUse: { try await tool.snapshot() })
    let scan = await f.scan(simulatorEngine: engine)
    let report = try #require(scan.report)
    let activeRow = try #require(report.items.first { $0.path == active.path })
    let unusedRow = try #require(report.items.first { $0.path == unused.path })
    let recentRow = try #require(report.items.first { $0.path == recent.path })
    guard case .inUse = scan.listMoveState(activeRow) else {
      Issue.record("Active npx must block a reviewed move")
      return
    }
    #expect(scan.listMoveState(recentRow) != .ready)
    let blocked = await engine.prepare(items: [activeRow, recentRow], reportID: report.id, projects: [],
      manual: scan.manualMoves)
    #expect(blocked.targets.isEmpty)
    let preview = await engine.prepare(items: [unusedRow], reportID: report.id, projects: [],
      manual: scan.manualMoves)
    #expect(preview.needsReview && preview.targets.count == 1)
    await tool.use(unused)
    #expect(try await engine.applyAfterTestConfirmation(preview, acknowledgedReview: true).moved.isEmpty)
    #expect(FileManager.default.fileExists(atPath: unused.path))
    await tool.use(active)
    let moved = try await engine.applyAfterTestConfirmation(preview, acknowledgedReview: true).moved
    let receipt = try #require(moved.first)
    let restored = try await engine.restore(receipt.id)
    #expect(restored.original.path == unused.path)
  }

  @Test func developerCachesRequireRecognizedFilesAndIdleProcesses() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let stats = try f.write("Library/Developer/Xcode/DerivedData/SDKStatCaches.noindex/test.sdkstatcache")
    try Data("STATfixture".utf8).write(to: stats)
    let apk = try f.write(".expo/android-apk-cache/Expo-Go-58.0.5.apk")
    try Data([0x50, 0x4b, 0x03, 0x04, 0x00]).write(to: apk)
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "journal"),
      simulatorStates: { [:] }, developmentUse: {
        try DevelopmentCacheUse(processList: "100 1 \(getuid()) node /test/node_modules/expo/bin/cli",
          openFiles: "p100\nn/private/tmp")
      })
    let scan = await f.scan(simulatorEngine: engine)
    let report = try #require(scan.report)
    let compiler = try #require(report.items.first { $0.path == stats.deletingLastPathComponent().path })
    let expo = try #require(report.items.first { $0.path == apk.deletingLastPathComponent().path })
    #expect(scan.listMoveState(compiler) == .ready)
    guard case .inUse = scan.listMoveState(expo) else {
      Issue.record("A running Expo CLI must block its download cache")
      return
    }
    try Data("unrecognized".utf8).write(to: stats)
    let preview = await engine.prepare(items: [compiler, expo], reportID: report.id, projects: [])
    #expect(preview.targets.isEmpty)
  }

  @Test func missingWorkspaceIntermediatesRequireContentAndUsageChecksAndRevalidateTheWorkspace() async throws {
    actor Activity {
      var active: URL?
      func set(_ url: URL?) { active = url }
      func reading() throws -> DevelopmentCacheUse {
        try DevelopmentCacheUse(processList: "100 1 \(getuid()) fixture",
          openFiles: "p100\nn" + (active?.path ?? "/private/tmp"))
      }
    }
    let f = try Fixture()
    defer { f.finish() }
    let workspace = f.home.appending(path: "Projects/Missing.xcodeproj")
    let base = "Library/Developer/Xcode/DerivedData/Missing-abc/"
    let plist = try f.write(base + "info.plist")
    try PropertyListEncoder().encode(["WorkspacePath": workspace.path]).write(to: plist)
    let relative = base + ProjectAttribution.intermediates
    let payload = try f.write(relative + "/ExplicitPrecompiledModules/output.pcm")
    try Data("CPCH".utf8 + Data(repeating: 7, count: 16384)).write(to: payload)
    let database = try f.write(relative + "/XCBuildData/build.db")
    try Data("SQLite format 3\0".utf8).write(to: database)
    let projectCopy = f.home.appending(path: "Projects/shared.pcm")
    try FileManager.default.createDirectory(at: projectCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let shared = payload.deletingLastPathComponent().appending(path: "shared.pcm")
    try Data("CPCH".utf8 + Data(repeating: 8, count: 16384)).write(to: projectCopy)
    try #require(clonefile(projectCopy.path, shared.path, 0) == 0)
    let log = try f.write(base + "Logs/keep.log")
    let root = f.home.appending(path: relative)
    let old = Date.now.addingTimeInterval(-48 * 60 * 60)
    func markOld(_ url: URL) throws {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    for url in [payload, shared, database, payload.deletingLastPathComponent(), database.deletingLastPathComponent(), root] {
      try markOld(url)
    }
    let activity = Activity()
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "journal"),
      simulatorStates: { [:] }, xcodeIdle: { true }, developmentUse: { try await activity.reading() })
    let scan = await f.scan(simulatorEngine: engine)
    let report = try #require(scan.report)
    let row = try #require(report.items.first { $0.path == root.path })
    #expect(row.profile == .xcodeOrphanBuild)
    let safe = scan.action(for: row)
    #expect(safe.risk == .safe && safe.bytes > 0 && safe.bytes < (row.bytes ?? 0))

    await activity.set(payload)
    #expect(await engine.prepare(items: [row], reportID: report.id, projects: []).targets.isEmpty)
    await activity.set(nil)
    let unexpected = try f.write(relative + "/ExplicitPrecompiledModules/notes.swift")
    try markOld(unexpected)
    try markOld(unexpected.deletingLastPathComponent())
    #expect(await engine.prepare(items: [row], reportID: report.id, projects: []).targets.isEmpty)
    try FileManager.default.removeItem(at: unexpected)
    #expect(await engine.prepare(items: [row], reportID: report.id, projects: []).targets.isEmpty)
    try markOld(unexpected.deletingLastPathComponent())
    let plan = await engine.prepare(items: [row], reportID: report.id, projects: [])
    #expect(!plan.needsReview && plan.targets.count == 1)
    #expect(plan.reclaimableBytes == safe.bytes)
    _ = try f.write("Projects/Missing.xcodeproj/project.pbxproj")
    #expect(try await engine.applyAfterTestConfirmation(plan).moved.isEmpty)
    #expect(FileManager.default.fileExists(atPath: payload.path))
    #expect(FileManager.default.fileExists(atPath: log.path))
    #expect(FileManager.default.fileExists(atPath: projectCopy.path))

    try FileManager.default.removeItem(at: workspace)
    let fresh = await engine.prepare(items: [row], reportID: report.id, projects: [])
    let moved = try await engine.applyAfterTestConfirmation(fresh).moved
    let receipt = try #require(moved.first)
    #expect(receipt.expectedRecoveryBytes == safe.bytes)
    #expect(FileManager.default.fileExists(atPath: projectCopy.path))
    _ = try await engine.restore(receipt.id)
    #expect(FileManager.default.fileExists(atPath: payload.path))
  }

  @Test func mixedLogCategoryExplainsSystemLogsAndConfirmsOnlyUserLogs() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let user = try f.write("Library/Logs/app.log")
    let system = f.home.deletingLastPathComponent().appending(path: UUID().uuidString)
    try Data(repeating: 1, count: 16384).write(to: system)
    defer { try? FileManager.default.removeItem(at: system) }
    let scan = await f.scan(extras: [
      ScanRoot(group: .logs, title: "System log", url: system, profile: .logs, source: .file)
    ])
    let logs = try #require(scan.report).items.filter { $0.category == ScanGroup.logs.rawValue }
    let protected = try #require(logs.first { $0.path == system.path })
    let movable = try #require(logs.first { $0.path == user.deletingLastPathComponent().path })
    let reason = try #require(scan.listMoveState(protected).explanation)
    #expect(reason == ReviewLanguage.text("Bu günlükleri macOS yönetir. MacPurge yalnızca kullanıcı klasöründeki günlükleri Çöp’e taşıyabilir."))
    #expect(scan.listMoveState(movable) == .ready)
    #expect(scan.overviewCandidates.filter { $0.category == ScanGroup.logs.rawValue }.map(\.id) == [movable.id])
    #expect(scan.storageReport?.items.contains { $0.id == protected.id } == true)
    #expect(scan.action(for: protected).risk == nil && scan.action(for: protected).bytes == 0)
    #expect(scan.distinctMoves(logs).map(\.id) == [movable.id])
    scan.cleanup.prepare([protected], scan: scan, explicit: true)
    #expect(scan.cleanup.preview == nil && !scan.cleanup.busy)
    scan.cleanup.prepare(logs, scan: scan, explicit: true, includeSkipped: true)
    #expect(scan.cleanup.busy)
    #expect(scan.listMoveState(movable) == .ready)
    #expect(scan.listMoveState(protected).explanation == reason)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(plan.needsReview && plan.targets.map(\.itemID) == [movable.id])
    #expect(plan.skipped == ["System log · " + reason])
    scan.cleanup.confirmMove(plan.id, scan: scan, acknowledgedReview: false)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.cleanup.outcome == nil && FileManager.default.fileExists(atPath: user.path))
    #expect(FileManager.default.fileExists(atPath: system.path))
  }

  // Synthetic inventory entries supply sizes without opening either real log directory.
  private var logFixture: ScanRoot {
    ScanRoot(group: .logs, title: "Unified system logs", url: URL(filePath: SystemLogStore.path),
      profile: .logs, source: .allocation(8192))
  }

  private actor AdminProbe {
    var calls = 0
    func invoke() { calls += 1 }
  }

  @Test func systemLogsRequireBothDecisionsAndNeverEnterTrash() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let marker = try f.write("Library/Logs/keep.log")
    let admin = AdminProbe()
    let archive = ScanRoot(group: .logs, title: "Text archive", url: URL(filePath: SystemLogStore.textArchive),
      profile: .logs, source: .allocation(4096))
    let scan = await f.scan(extras: [logFixture, archive], eraseSystemLogs: { await admin.invoke() })
    let report = try #require(scan.report)
    let row = try #require(report.items.first { $0.path == SystemLogStore.path })
    let user = try #require(report.items.first { $0.path == marker.deletingLastPathComponent().path })
    #expect(scan.filterRisk(for: row) == .review && scan.overviewCandidates.contains(row))
    #expect(!scan.distinctMoves([row, user]).contains(row))
    #expect(scan.explicitSelection([row.id], in: report).isEmpty)
    #expect(scan.action(for: user).permanentOperation == nil)
    let text = try #require(report.items.first { $0.path == SystemLogStore.textArchive })
    #expect(scan.action(for: text).permanentOperation == nil)
    let session = scan.cleanup
    session.prepare([row], scan: scan, explicit: true)
    #expect(session.preview == nil && !session.busy)
    session.reviewPermanentCleanup(row, scan: scan)
    let abandoned = try #require(session.permanentReview)
    session.confirmPermanentCleanup(abandoned, scan: scan)
    #expect(abandoned.stage == .review && !session.busy)
    abandoned.acknowledge()
    session.permanentReview = nil  // dismiss after the first decision
    session.confirmPermanentCleanup(abandoned, scan: scan)
    session.reviewPermanentCleanup(row, scan: scan)
    let current = try #require(session.permanentReview)
    session.confirmPermanentCleanup(abandoned, scan: scan)
    #expect(current.stage == .review && !session.busy)
    #expect(await admin.calls == 0)
    current.acknowledge()
    #expect(current.stage == .confirmation)
    #expect(await admin.calls == 0)
    session.confirmPermanentCleanup(current, scan: scan)
    session.confirmPermanentCleanup(current, scan: scan)
    await session.finishCurrentOperation()
    if case .result(let message) = current.stage {
      #expect(message == ReviewLanguage.text("System logs were cleared. macOS continues to record new entries."))
    } else { Issue.record("Missing completion") }
    #expect(await admin.calls == 1 && !session.busy)
    #expect(scan.report?.free == 3_999_987)
    #expect(await f.probe.discovery == 1)
    #expect(session.outcome == nil && session.receipts.isEmpty && FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func staleLogReviewAndAuthorizationErrorsDoNotReportSuccess() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let admin = AdminProbe()
    let scan = await f.scan(extras: [logFixture], eraseSystemLogs: {
      await admin.invoke()
      if await admin.calls == 1 { throw CancellationError() }
      throw CocoaError(.fileWriteNoPermission)
    })
    let session = scan.cleanup
    let oldRow = try #require(scan.report?.items.first { $0.path == SystemLogStore.path })
    session.reviewPermanentCleanup(oldRow, scan: scan)
    let stale = try #require(session.permanentReview)
    stale.acknowledge()
    scan.startDetailed()
    session.confirmPermanentCleanup(stale, scan: scan)
    #expect(await admin.calls == 0 && !session.busy)
    #expect(stale.stage == .result(ReviewLanguage.text("The scan changed. Review the system logs again.")))
    await scan.finishCurrentScan()
    await scan.refreshMoveStates()
    let report = try #require(scan.report)
    let current = try #require(report.items.first { $0.path == SystemLogStore.path })
    for attempt in 1...2 {
      session.permanentReview = nil
      session.reviewPermanentCleanup(current, scan: scan)
      let review = try #require(session.permanentReview)
      review.acknowledge()
      session.confirmPermanentCleanup(review, scan: scan)
      await session.finishCurrentOperation()
      if case .result(let message) = review.stage {
        if attempt == 1 {
          #expect(message == ReviewLanguage.text("Authorization was cancelled."))
        } else {
          #expect(message.hasPrefix(ReviewLanguage.text("macOS could not confirm that the logs were cleared.")))
        }
      } else { Issue.record("Missing error result") }
      #expect(!session.busy && session.receipts.isEmpty && scan.report?.id == report.id)
    }
    #expect(await admin.calls == 2)
  }

  @Test func targetedRemeasureReadsBothLogStoresAndKeepsUnrelatedRows() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let store = try f.write("diagnostics/a.trace")
    let archive = try f.write("uuidtext/b")
    let other = try f.write("crash/report")
    let dirs = [store, archive, other].map { $0.deletingLastPathComponent() }
    let roots = dirs.map { ScanRoot(group: .logs, title: $0.lastPathComponent, url: $0, profile: .logs) }
    var sizes: [String: RootSize] = [:]
    for root in roots { sizes[root.id] = try await StorageMeter.measure(root) }
    let original = ScanReport.make(roots: roots, results: sizes, disk: nil, extended: true, homeDevice: nil)
    // Change a third fixture too, so an accidental full remeasurement is observable.
    for file in [store, archive, other] { try Data().write(to: file) }
    let patch = try await CleanupMeasurement.read(receipts: [], trash: f.home.appending(path: ".Trash"),
      restored: false, disk: nil, remeasurePaths: Set(dirs.prefix(2).map(\.path)),
      roots: roots, results: sizes, report: original, simulatorListIncomplete: false,
      home: f.home, projects: [], artifacts: [])
    #expect(Set(patch.freshItems.map(\.path)) == Set(dirs.prefix(2).map(\.path)))
    for root in roots.prefix(2) {
      #expect(try await StorageMeter.measure(root).bytes == patch.results[root.id]?.bytes)
      #expect(patch.results[root.id]!.bytes < sizes[root.id]!.bytes)
    }
    #expect(patch.results[roots[2].id]?.bytes == sizes[roots[2].id]?.bytes)
  }

  @Test func npmIsOneActionAndBecomesMovableWhenTheOwnerExits() async throws {
    actor Owner {
      var idle = false
      func finish() { idle = true }
    }
    let f = try Fixture()
    defer { f.finish() }
    let owner = Owner()
    let content = try f.write(".npm/_cacache/content-v2/pkg")
    let index = try f.write(".npm/_cacache/index-v5/index")
    // A second inventory source must not offer a manual move around the package owner check.
    let alias = ScanRoot(group: .tools, title: "Same cache contents",
      url: content.deletingLastPathComponent(), profile: .personal)
    let scan = await f.scan(extras: [alias], packageIdle: { tool in
      if tool == .npm { return await owner.idle }
      return true
    })
    let report = try #require(scan.report)
    let cache = content.deletingLastPathComponent().deletingLastPathComponent()
    let row = try #require(report.items.first { $0.path == cache.path })
    #expect(Set(row.parts.keys).isSuperset(of: ["content-v2", "index-v5"]))
    #expect(!report.items.contains { $0.category == ScanGroup.packages.rawValue && $0.path.hasPrefix(cache.path + "/") })
    let other = try #require(report.items.first { $0.path == alias.url.path })
    #expect(scan.action(for: other).risk == nil)
    #expect(!scan.manualMoves.values.contains { $0.path.hasPrefix(cache.path + "/") })
    guard case .unavailable(.inUse) = scan.action(for: row) else {
      Issue.record("Busy npm must show its owner restriction"); return
    }
    #expect(scan.explicitSelection([row.id], in: report).isEmpty)
    #expect(!scan.overviewCandidates.contains { $0.id == row.id })
    #expect(scan.storageReport?.items.contains { $0.id == row.id } == true)
    await owner.finish()
    await scan.refreshMoveStates(only: [row.id])
    #expect(scan.action(for: row) == .move(.safe, bytes: row.bytes ?? -1))
    #expect(scan.overviewCandidates.contains { $0.id == row.id })
    scan.cleanup.prepare([row], scan: scan, explicit: true)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(!plan.needsReview && plan.targets.map(\.path.path) == [cache.path])
    #expect(FileManager.default.fileExists(atPath: content.path))
    scan.cleanup.confirmMove(plan.id, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    scan.cleanup.restore(try #require(scan.cleanup.receipts.first), scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(FileManager.default.fileExists(atPath: content.path) && FileManager.default.fileExists(atPath: index.path))
  }

  @Test func overlappingSelectionsCountAndMoveTheParentOnce() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let file = try f.write("Library/LocalTool/project/output/bin")
    let child = file.deletingLastPathComponent()
    let parent = child.deletingLastPathComponent()
    let scan = await f.scan(extras: [
      .init(group: .tools, title: "Project data", url: parent, profile: .personal),
      .init(group: .apps, title: "Output", url: child, profile: .personal),
    ])
    let rows = try #require(scan.report).items.filter { $0.path == parent.path || $0.path == child.path }
    #expect(rows.count == 2)
    #expect(scan.distinctMoves(rows).map(\.path) == [parent.path])
    scan.cleanup.prepare(rows, scan: scan, explicit: true)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(plan.targets.map(\.path.path) == [parent.path] && plan.needsReview)
    scan.cleanup.confirmMove(plan.id, scan: scan, acknowledgedReview: true)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.cleanup.receipts.count == 1 && !FileManager.default.fileExists(atPath: parent.path))
    scan.cleanup.restore(try #require(scan.cleanup.receipts.first), scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func manualArchiveRequiresRiskAcknowledgementAndRestores() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let archive = try f.write("Library/Developer/Xcode/Archives/2026-10-01/v1.xcarchive/Contents/archive")
      .deletingLastPathComponent().deletingLastPathComponent()
    let other = try f.write("Library/Developer/Xcode/Archives/2026-10-01/v2.xcarchive/Contents/archive")
    let roots = try ExtendedInventory.xcodeEntries(in: f.home.appending(path: "Library/Developer/Xcode/Archives"), device: nil)
    #expect(Set(roots.map(\.title)) == ["v1.xcarchive", "v2.xcarchive"])
    let scan = await f.scan(extras: roots)
    let report = try #require(scan.report)
    let row = try #require(report.items.first { $0.path == archive.path })
    #expect(scan.manualMoves[row.id] != nil && scan.listMoveState(row) == .ready)
    #expect(report.plan(target: 1, moveStates: scan.moveStates).isEmpty)
    scan.cleanup.prepare([row], scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.cleanup.preview == nil)
    scan.cleanup.prepare([row], scan: scan, explicit: true)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(plan.targets.first?.review?.warning.contains("Arşivler") == true)
    var pending: TrashPlan? = plan
    #expect(
      ConfirmedTrashPlan(confirming: plan.id, preview: &pending, currentReportID: report.id) == nil)
    #expect(FileManager.default.fileExists(atPath: archive.path))
    scan.cleanup.confirmMove(plan.id, scan: scan, acknowledgedReview: true)
    await scan.cleanup.finishCurrentOperation()
    let receipt = try #require(scan.cleanup.receipts.first)
    #expect(!FileManager.default.fileExists(atPath: archive.path) && receipt.review != nil)
    #expect(scan.report?.items.contains { $0.id == row.id } == false)
    #expect(FileManager.default.fileExists(atPath: other.path))
    // Reopen with a fresh scan while the dynamic folder is still in the Trash.
    let reopened = await f.scan()
    reopened.cleanup.restore(receipt, scan: reopened)
    await reopened.cleanup.finishCurrentOperation()
    #expect(
      FileManager.default.fileExists(
        atPath: archive.appending(path: "Contents/archive").path))
    #expect(reopened.report?.items.first { $0.id == row.id }?.bytes == row.bytes)
    #expect(reopened.cleanup.receipts.isEmpty)
  }

  @Test func manualFileRoundTripAndMixedSelectionExcludeUnmeasuredAndProtectedTargets() async throws
  {
    let f = try Fixture()
    defer { f.finish() }
    let file = try f.write("Library/Caches/test/image.bin")
    let npm = try f.write(".npm/_cacache/a").deletingLastPathComponent()
    let project = try f.write("Projects/source").deletingLastPathComponent()
    let review = ScanRoot(
      group: .apps, title: "image", url: file, profile: .personal, source: .file)
    let logical = ScanRoot(
      group: .models, title: "model share", url: file,
      profile: .personal, source: .allocation(100))
    let scan = await f.scan(project: project, extras: [review, logical])
    let report = try #require(scan.report)
    let items = report.items.filter {
      $0.path == file.path || $0.path == npm.path || $0.path == project.path
    }
    #expect(scan.explicitSelection(Set(items.map(\.id)), in: report).count == 2)
    scan.cleanup.prepare(items, scan: scan, explicit: true)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(plan.needsReview && Set(plan.targets.map(\.path.path)) == [file.path, npm.path])
    var proposed: TrashPlan? = plan
    #expect(ConfirmedTrashPlan(confirming: plan.id, preview: &proposed, currentReportID: report.id) == nil)
    #expect(FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: npm.path))
    scan.cleanup.confirmMove(plan.id, scan: scan, acknowledgedReview: true)
    await scan.cleanup.finishCurrentOperation()
    let receipt = try #require(scan.cleanup.receipts.first { $0.original.path == file.path })
    #expect(receipt.review?.file == true)
    #expect(
      scan.report?.items.contains { $0.category == ScanGroup.apps.rawValue && $0.path == file.path }
        == false)
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(try Data(contentsOf: file).count == 16384)
    #expect(
      scan.report?.items.first { $0.category == ScanGroup.apps.rawValue && $0.path == file.path }?
        .bytes == receipt.bytes)
  }

  @Test func productActionsAreIndependentAndNeverIncludeTheirParent() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let child = try f.write("Library/Developer/Xcode/Products/app.first/content")
      .deletingLastPathComponent()
    let sibling = try f.write("Library/Developer/Xcode/Products/app.second/content")
    let roots = try ExtendedInventory.xcodeEntries(in: child.deletingLastPathComponent(), device: nil)
    let scan = await f.scan(extras: roots)
    let report = try #require(scan.report)
    let row = try #require(report.items.first { $0.path == child.path })
    #expect(!report.items.contains { $0.path == child.deletingLastPathComponent().path })
    #expect(scan.action(for: row).risk == .review)
    scan.cleanup.prepare([row], scan: scan, explicit: true)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(plan.needsReview && plan.targets.map(\.path.path) == [child.path])
    scan.cleanup.confirmMove(plan.id, scan: scan, acknowledgedReview: true)
    await scan.cleanup.finishCurrentOperation()
    let receipt = try #require(scan.cleanup.receipts.first)
    #expect(FileManager.default.fileExists(atPath: sibling.path))
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.report?.items.first { $0.id == row.id }?.bytes == row.bytes)
  }

  @Test func replacedReviewDirectoryCannotMoveUsingOldMeasurement() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let dir = try f.write("Library/Caches/test/old").deletingLastPathComponent()
    let root = ScanRoot(group: .apps, title: "test", url: dir)
    let scan = await f.scan(extras: [root])
    let row = try #require(scan.report?.items.first { $0.path == dir.path })
    try FileManager.default.moveItem(at: dir, to: f.home.appending(path: "elsewhere"))
    _ = try f.write("Library/Caches/test/new")
    scan.cleanup.prepare([row], scan: scan, explicit: true)
    await scan.cleanup.finishCurrentOperation()
    let plan = try #require(scan.cleanup.preview)
    #expect(plan.targets.isEmpty && !plan.skipped.isEmpty && scan.cleanup.receipts.isEmpty)
  }

  @Test func moveAndRestoreUpdateOnlyOwnedRootsAndActualFreeSpace() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let npm = try f.write(".npm/_cacache/data").deletingLastPathComponent()
    let go = try f.write("Library/Caches/go-build/unrelated").deletingLastPathComponent()
    let a = try f.write("hardlinks/a/file")
    let b = try f.write("hardlinks/b/other")
    try FileManager.default.linkItem(
      at: a, to: b.deletingLastPathComponent().appending(path: "alias"))
    let project = npm.deletingLastPathComponent()
    let scan = await f.scan(
      project: project,
      extras: [a, b].map {
        .init(group: .packages, title: $0.path, url: $0.deletingLastPathComponent())
      })
    let before = try #require(scan.report)
    let npmRow = try #require(before.items.first { $0.path == npm.path })
    let goRow = try #require(before.items.first { $0.path == go.path })
    let bytes = try #require(npmRow.bytes)
    let packages = try #require(scan.groupBytes[.packages])
    let full = scan.inventoryID
    // A fresh full scan, or even a rescan of every package, would observe this write.
    _ = try f.write("Library/Caches/go-build/new", 65536)
    let moved = try await move([npmRow], scan: scan)
    let receipt = try #require(moved.first)
    let after = try #require(scan.storageReport)
    #expect(scan.phase == .finished && scan.inventoryID == full && before.id != after.id)
    #expect(scan.measuredAt == before.date && after.date == before.date)
    #expect(after.items.first(where: { $0.id == goRow.id }) == goRow)
    #expect(!after.items.contains { $0.id == npmRow.id })
    #expect(scan.groupBytes[.packages] == packages - bytes)
    #expect(after.groups?[ScanGroup.packages.rawValue] == packages - bytes)
    #expect(scan.groupBytes[.trash] == bytes && scan.groupBytes[.projects] == 0)
    #expect(
      scan.overviewCategories[.packages]?.largest.contains { $0.root.url.path == npm.path } == false
    )
    #expect(after.free == 3_999_974 && scan.volume?.free == after.free)
    #expect(scan.cleanup.outcome?.freeChange == -13)
    #expect(scan.moveStates[npmRow.id] == nil)
    // An occupied original path must not be overwritten or start a scan.
    _ = try f.write(".npm/_cacache/new-owner")
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.report?.id == after.id && scan.cleanup.receipts.count == 1)
    try FileManager.default.moveItem(at: npm, to: f.home.appending(path: "displaced-test-folder"))
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    let restored = try #require(scan.report)
    let fresh = try #require(restored.items.first { $0.id == npmRow.id })
    #expect(fresh.bytes == bytes && fresh.measuredAt != nil && scan.moveStates[fresh.id] == .ready)
    #expect(restored.items.first(where: { $0.id == goRow.id }) == goRow)
    #expect(scan.groupBytes[.packages] == packages && scan.groupBytes[.projects] == bytes)
    #expect(scan.groupBytes[.trash] == 0 && scan.cleanup.receipts.isEmpty)
    #expect(restored.groupSafety == before.groupSafety)
    #expect(scan.volume?.free == 3_999_961 && restored.free == scan.volume?.free)
    #expect(scan.inventoryID == full && scan.measuredAt == before.date)
    #expect(await f.probe.discovery == 1)
    #expect(await f.probe.tools == 1)
    #expect(await f.probe.disk == 3)
  }

  @Test func projectTotalsRespectTheVolumesCaseRulesOnCleanup() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let cache = try f.write("Library/Caches/Go-Build/data").deletingLastPathComponent()
    let parent = cache.deletingLastPathComponent()
    let scan = await f.scan(project: parent)
    let row = scan.report?.items.first { $0.path.hasSuffix("/go-build") && $0.eligibleBytes > 0 }
    if !FileManager.default.fileExists(atPath: parent.appending(path: "go-build").path) {
      #expect(row == nil)
      return
    }
    let candidate = try #require(row)
    let receipt = try #require(try await move([candidate], scan: scan).first)
    #expect(scan.groupBytes[.projects] == 0)
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.groupBytes[.projects] == receipt.bytes)
  }

  @Test func stopAfterRestoreStillPublishesChangedFolderAndFreeSpace() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let npm = try f.write(".npm/_cacache/data").deletingLastPathComponent()
    let scan = await f.scan()
    let row = try #require(scan.report?.items.first { $0.path == npm.path })
    let receipt = try #require(try await move([row], scan: scan).first)
    await f.probe.whenReading { await scan.cleanup.cancel() }
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.report?.items.first { $0.id == row.id }?.bytes == row.bytes)
    #expect(scan.volume?.free == 3_999_961 && scan.report?.free == scan.volume?.free)
    #expect(scan.cleanup.receipts.isEmpty && FileManager.default.fileExists(atPath: npm.path))
  }

  @Test func homeContainingBothRenameEndpointsKeepsUnrelatedBytesAndProjectMetadata() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let npm = try f.write(".npm/_cacache/.build/data").deletingLastPathComponent()
      .deletingLastPathComponent()
    _ = try f.write("Sources/main.swift")
    let scan = await f.scan(project: f.home)
    let row = try #require(scan.report?.items.first { $0.path == npm.path })
    let project = try #require(scan.roots.first { $0.group == .projects })
    let before = try #require(scan.results[project.id])
    _ = try f.write("Sources/unrelated", 65536)
    let receipt = try #require(try await move([row], scan: scan).first)
    let moved = try #require(scan.results[project.id])
    #expect(moved.bytes == before.bytes && moved.files == before.files)
    #expect(moved.largest[".Trash"] == receipt.bytes && moved.outputKinds == before.outputKinds)
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    let restored = try #require(scan.results[project.id])
    #expect(restored.bytes == before.bytes && restored.files == before.files)
    #expect(restored.largest == before.largest && restored.outputKinds == before.outputKinds)
    #expect(
      restored.modified == before.modified && restored.sourceModified == before.sourceModified)
  }

  @Test func simulatorEraseChecksTheSelectedDeviceAgainAfterBothDecisions() async throws {
    actor Devices {
      var states: [UUID: SimulatorState] = [:]
      var erased: [UUID] = []
      func set(_ id: UUID, _ value: String?) {
        states[id] = value.map { SimulatorState(state: $0 == "Unavailable" ? "Shutdown" : $0, isAvailable: $0 != "Unavailable") }
      }
      func record(_ id: UUID) { erased.append(id) }
    }
    let f = try Fixture()
    defer { f.finish() }
    let devices = Devices()
    let first = UUID(), second = UUID()
    let base = "Library/Developer/CoreSimulator/Devices/"
    for id in [first, second] {
      let dir = base + id.uuidString
      let plist = try f.write(dir + "/device.plist")
      try PropertyListEncoder().encode(["name": "Twin"]).write(to: plist)
      try f.write(dir + "/data/Documents/user")
      try f.write(dir + "/data/tmp/cache")
      await devices.set(id, "Shutdown")
    }
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "journal"),
      simulatorStates: { await devices.states }, eraseSimulator: { id, _ in await devices.record(id) })
    let scan = await f.scan(simulatorEngine: engine)
    let report = try #require(scan.report)
    let row = try #require(report.items.first { $0.simulatorDataDevice?.id == second })
    let cache = try #require(report.items.first { $0.path == row.path && $0.id != row.id })
    let op = try #require(scan.action(for: row).permanentOperation)
    #expect(op.confirmButton.contains("Twin") && scan.action(for: row).risk == .review)
    #expect(scan.action(for: cache).risk == .safe && scan.action(for: cache).permanentOperation == nil)
    #expect(scan.explicitSelection([row.id, cache.id], in: report).map(\.id) == [cache.id])
    let session = scan.cleanup
    session.reviewPermanentCleanup(row, scan: scan)
    let cancelled = try #require(session.permanentReview)
    session.confirmPermanentCleanup(cancelled, scan: scan) // cannot skip risk acknowledgement
    #expect(cancelled.stage == .review && !session.busy)
    cancelled.acknowledge()
    session.permanentReview = nil
    session.confirmPermanentCleanup(cancelled, scan: scan)
    #expect(await devices.erased.isEmpty)
    for state in ["Booted", "Booting", "Shutting Down", "Unavailable", nil] as [String?] {
      await devices.set(second, "Shutdown")
      await scan.refreshMoveStates(only: [row.id])
      session.reviewPermanentCleanup(row, scan: scan)
      let review = try #require(session.permanentReview)
      review.acknowledge()
      await devices.set(second, state) // other device still shut down
      session.confirmPermanentCleanup(review, scan: scan)
      await session.finishCurrentOperation()
      #expect(await devices.erased.isEmpty)
      #expect(scan.action(for: row).risk == .review && scan.action(for: row).permanentOperation == nil)
      session.permanentReview = nil
    }
    await devices.set(second, "Shutdown")
    await scan.refreshMoveStates(only: [row.id])
    session.reviewPermanentCleanup(row, scan: scan)
    let accepted = try #require(session.permanentReview)
    accepted.acknowledge()
    session.confirmPermanentCleanup(accepted, scan: scan)
    session.confirmPermanentCleanup(accepted, scan: scan)
    await session.finishCurrentOperation()
    #expect(await devices.erased == [second])
    #expect(scan.report?.items.first(where: { $0.id == cache.id })?.eligibleBytes == cache.eligibleBytes)
    #expect(session.receipts.isEmpty && session.outcome == nil)
    #expect(await f.probe.discovery == 1)
  }

  // Requires an installed simulator runtime. Both devices are created inside a temporary
  // device set, and the normal app flow passes that same set to simctl for the erase.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MACPURGE_TEST_SIM_RUNTIME"] != nil))
  func erasesOnlyTheChosenTwinInAnIsolatedCoreSimulatorSet() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let runtime = try #require(ProcessInfo.processInfo.environment["MACPURGE_TEST_SIM_RUNTIME"])
    let type = try #require(ProcessInfo.processInfo.environment["MACPURGE_TEST_SIM_TYPE"])
    let set = f.home.appending(path: "Library/Developer/CoreSimulator/Devices")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    func createTwin() async throws -> UUID {
      let raw = try await CleanupCommand.run("/usr/bin/xcrun",
        ["simctl", "--set", set.path, "create", "MacPurge Test Twin", type, runtime])
      let id = try #require(UUID(uuidString: raw))
      for _ in 0..<50 {
        if try await CacheTrash.simulatorStates(in: set)[id]?.state == "Shutdown" { return id }
        try await Task.sleep(for: .milliseconds(200))
      }
      throw CleanupFailure("Test simulator did not reach Shutdown")
    }
    let chosen = try await createTwin()
    let sibling = try await createTwin()
    let base = "Library/Developer/CoreSimulator/Devices/"
    let marker = try f.write(base + chosen.uuidString + "/data/Documents/macpurge-marker", 524288)
    let kept = try f.write(base + sibling.uuidString + "/data/Documents/macpurge-marker", 32768)
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "journal"))
    let scan = await f.scan(simulatorEngine: engine)
    let before = try #require(scan.report)
    let row = try #require(before.items.first { $0.simulatorDataDevice?.id == chosen })
    let other = try #require(before.items.first { $0.simulatorDataDevice?.id == sibling })
    scan.cleanup.reviewPermanentCleanup(row, scan: scan)
    let review = try #require(scan.cleanup.permanentReview)
    review.acknowledge()
    #expect(FileManager.default.fileExists(atPath: marker.path))
    scan.cleanup.confirmPermanentCleanup(review, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(review.stage == .result(ReviewLanguage.format("%@ was reset to factory settings.", "MacPurge Test Twin")))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try Data(contentsOf: kept).count == 32768)
    let states = try await CacheTrash.simulatorStates(in: set)
    #expect(states[chosen]?.state == "Shutdown" && states[sibling]?.state == "Shutdown")
    let after = try #require(scan.report)
    #expect(after.items.first(where: { $0.id == other.id }) == other)
    #expect(after.items.first(where: { $0.id == row.id })?.measuredAt != nil)
    #expect(scan.volume?.free == after.free && after.free != nil)
    #expect(await f.probe.discovery == 1)
  }

  @Test func nestedSimulatorCacheRefreshesItsOwnDeviceInBothDirections() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let phone = UUID()
    let other = UUID()
    let base = "Library/Developer/CoreSimulator/Devices/"
    let path = base + phone.uuidString
    let cache = try f.write(path + "/data/Library/Caches/a").deletingLastPathComponent()
    _ = try f.write(path + "/data/tmp/b", 8192)
    _ = try f.write(path + "/data/Documents/doc", 32768)
    _ = try f.write(base + other.uuidString + "/data/Documents/other")
    let scan = await f.scan(device: phone, realVolume: true)
    let before = try #require(scan.report)
    let root = f.home.appending(path: path).path
    let row = try #require(before.items.first { $0.path == root && $0.eligibleBytes > 0 })
    let personal = try #require(before.items.first { $0.path == root && $0.eligibleBytes == 0 })
    _ = try f.write(base + other.uuidString + "/data/Documents/unrelated", 65536)
    _ = try f.write(path + "/data/Documents/not-remeasured", 65536)
    let moved = try await move([row], scan: scan, onlyPath: cache)
    let receipt = try #require(moved.first)
    let after = try #require(scan.report)
    #expect(
      after.items.first(where: { $0.id == row.id })?.bytes == (row.bytes ?? 0) - receipt.bytes)
    #expect(after.items.first(where: { $0.id == personal.id })?.bytes == personal.bytes)
    let diskAfterMove = try #require(await f.probe.observedFree)
    #expect(after.free == diskAfterMove && scan.volume?.free == diskAfterMove)
    let sibling = f.home.appending(path: base + other.uuidString).path
    #expect(after.items.filter { $0.path == sibling } == before.items.filter { $0.path == sibling })
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.report?.groupSafety == before.groupSafety)
    #expect(scan.report?.items.first(where: { $0.id == row.id })?.bytes == row.bytes)
    let diskAfterRestore = try #require(await f.probe.observedFree)
    #expect(scan.report?.free == diskAfterRestore && scan.volume?.free == diskAfterRestore)
    #expect(await f.probe.discovery == 1)
  }
  @Test func restoredXcodeOutputMissingFromNewInventoryIsAttributedOnce() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let project = f.home.appending(path: "Projects/Fixture")
    let workspace = try f.write("Projects/Fixture/Test.xcodeproj/project.pbxproj")
      .deletingLastPathComponent()
    let base = "Library/Developer/Xcode/DerivedData/Test-abc/"
    let meta = try f.write(base + "info.plist")
    try PropertyListEncoder().encode(["WorkspacePath": workspace.path]).write(to: meta)
    let path = try f.write(base + "Build/Intermediates.noindex/files").deletingLastPathComponent()
    _ = try f.write(base + "Build/Products/keep")
    let first = await f.scan(project: project)
    let before = try #require(first.report)
    let output = try #require(before.items.first { $0.path == path.path })
    let receipt = try #require(try await move([output], scan: first).first)
    let projectBytes = try #require(first.projectArtifacts.first?.bytes)
    // A later session discovers no intermediates row while the output is in the Trash.
    let reopened = await f.scan(project: project)
    let inventory = reopened.inventoryID
    #expect(reopened.report?.items.contains { $0.path == path.path } == false)
    reopened.cleanup.restore(receipt, scan: reopened)
    await reopened.cleanup.finishCurrentOperation()
    let restored = try #require(reopened.report)
    #expect(reopened.inventoryID == inventory)
    #expect(restored.items.filter { $0.path == path.path }.count == 1)
    #expect(restored.items.first { $0.id == output.id }?.workspace == workspace.path)
    #expect(restored.groups?[ScanGroup.xcode.rawValue] == before.groups?[ScanGroup.xcode.rawValue])
    #expect(reopened.projectArtifacts.first?.bytes == projectBytes + (output.bytes ?? 0))
    #expect(reopened.moveStates[output.id] == .ready)
    #expect(await f.probe.discovery == 2)
  }

  @Test func restoreAfterInterruptedRescanPatchesTheVisibleSnapshotWithoutRestartingIt()
    async throws
  {
    let f = try Fixture()
    defer { f.finish() }
    let npm = try f.write(".npm/_cacache/a").deletingLastPathComponent()
    let go = try f.write("Library/Caches/go-build/b").deletingLastPathComponent()
    let scan = await f.scan()
    let row = try #require(scan.report?.items.first { $0.path == npm.path })
    let other = try #require(scan.report?.items.first { $0.path == go.path })
    let receipt = try #require(try await move([row], scan: scan).first)
    scan.startDetailed()
    scan.cancel()
    await scan.finishCurrentScan()
    let token = scan.inventoryID
    scan.cleanup.restore(receipt, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.phase == .cancelled && scan.inventoryID == token)
    let patched = try #require(scan.storageReport)
    #expect(patched.items.first { $0.id == row.id }?.bytes == row.bytes)
    #expect(patched.items.first { $0.id == other.id } == other)
    #expect(patched.items.first { $0.category == ScanGroup.trash.rawValue }?.bytes == 0)
    #expect(patched.groups?[ScanGroup.packages.rawValue] == nil)
    #expect(patched.free == scan.volume?.free)
    #expect(await f.probe.discovery == 1)
  }

  @Test func partialBatchRefreshesOnlyTheSuccessfulRename() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let npm = try f.write(".npm/_cacache/a").deletingLastPathComponent()
    let go = try f.write("Library/Caches/go-build/b").deletingLastPathComponent()
    let scan = await f.scan()
    let prior = try #require(scan.report)
    let rows = prior.items.filter { $0.path == npm.path || $0.path == go.path }
    scan.cleanup.prepare(rows, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    let preview = try #require(scan.cleanup.preview)
    _ = try f.write("Library/Caches/go-build/changed-after-preview", 65536)
    scan.cleanup.confirmMove(preview.id, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(scan.cleanup.outcome?.moved.map { $0.original.path } == [npm.path])
    #expect(scan.report?.items.contains { $0.path == npm.path } == false)
    #expect(scan.report?.items.first { $0.path == go.path } == rows.first { $0.path == go.path })
    #expect(await f.probe.discovery == 1)
  }
}
