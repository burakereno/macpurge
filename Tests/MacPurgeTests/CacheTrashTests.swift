import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

extension CacheTrash {
  func applyAfterTestConfirmation(
    _ plan: TrashPlan, acknowledgedReview: Bool = false
  ) async throws -> TrashOutcome {
    var preview: TrashPlan? = plan
    let accepted = try #require(
      ConfirmedTrashPlan(confirming: plan.id, preview: &preview, currentReportID: plan.reportID,
        acknowledgedReview: acknowledgedReview))
    return await apply(accepted)
  }
}

struct CacheTrashTests {
  private struct Fixture {
    let home = URL(fileURLWithPath: "/private/tmp")
      .appending(path: "MacPurge-TrashTest-" + UUID().uuidString)
    var bin: URL { home.appending(path: ".Trash") }
    var journal: URL { home.appending(path: "receipts") }
    var npm: URL { home.appending(path: ".npm/_cacache") }
    var go: URL { home.appending(path: "Library/Caches/go-build") }
    func store(shutdown: Bool = true, device: UUID? = nil) -> CacheTrash {
      CacheTrash(
        home: home, journal: journal,
        simulatorStates: { device.map { [$0: SimulatorState(state: shutdown ? "Shutdown" : "Booted")] } ?? [:] },
        xcodeIdle: { true }, packageIdle: { _ in true })
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

  @Test func projectIdentityBlocksCaseAndSymlinkAliasesEvenAtApply() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let project = f.go.appending(path: "Work")
    try f.write(project)
    let link = f.home.appending(path: "chosen")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
    let engine = f.store()
    let row = try f.row(f.go)
    var selected = [link]
    let alias = f.home.appending(path: "Library/Caches/GO-BUILD/Work")
    if FileManager.default.fileExists(atPath: alias.path) { selected.append(alias) }
    for path in selected {
      let plan = await engine.prepare(items: [row], reportID: UUID(), projects: [path])
      #expect(plan.targets.isEmpty)
    }
    // A selection can be redirected after the preview without changing cache contents.
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.bin)
    let preview = await engine.prepare(items: [row], reportID: UUID(), projects: [link])
    #expect(preview.targets.count == 1)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
    #expect(try await engine.applyAfterTestConfirmation(preview).moved.isEmpty)
    #expect(FileManager.default.fileExists(atPath: project.appending(path: "payload").path))
  }

  @Test func displayReusesScanButPreviewStillRejectsNewNestedSymlink() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let nested = f.npm.appending(path: "nested")
    try f.write(nested)
    let root = ScanRoot(group: .packages, title: "npm", url: f.npm, profile: .npmCache)
    let size = try await StorageMeter.measure(root)
    let row = try f.row(f.npm)
    let engine = f.store()
    try FileManager.default.createSymbolicLink(
      at: nested.appending(path: "unsafe"), withDestinationURL: f.bin)
    #expect(
      try await engine.availability(
        for: [row], projects: [], reportID: UUID(),
        readings: size.cleanupReadings)[row.id] == .ready)
    #expect(await engine.prepare(items: [row], reportID: UUID(), projects: []).targets.isEmpty)
  }

  @Test func shortcutsUseLiveSizesIncludingPreviouslyEmptySafeRoots() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    try f.write(f.go)
    var old = try f.row(f.npm)
    old.eligibleBytes = 10_000_000_000
    var empty = try f.row(f.go)
    empty.bytes = 0
    empty.eligibleBytes = 0
    let archive = ScanReport(
      id: UUID(), date: .distantPast, extended: false, free: nil, capacity: nil,
      items: [old, empty])
    let engine = f.store()
    let current = try await engine.currentPlanInputs(archive, projects: [], hidden: [])
    let plan = current.report.plan(target: 1_000_000_000, moveStates: current.states)
    #expect(Set(plan.map(\.id)) == [old.id, empty.id])
    let actual = await engine.prepare(items: plan, reportID: archive.id, projects: []).targets
      .reduce(Int64(0)) { $0 + $1.snapshot.bytes }
    #expect(plan.reduce(0) { $0 + $1.eligibleBytes } == actual && actual < 1_000_000_000)
    #expect(plan.allSatisfy { $0.directoryInode != nil && $0.measuredAt != nil })
  }

  @Test func emptiedTrashPrunesOnlyTheDepartedReceipt() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let engine = f.store()
    try f.write(f.npm)
    try f.write(f.go)
    let preview = await engine.prepare(
      items: [try f.row(f.npm), try f.row(f.go)], reportID: UUID(), projects: [])
    let receipts = try await engine.applyAfterTestConfirmation(preview).moved
    let removed = try #require(receipts.first)
    let kept = try #require(receipts.last)
    #expect(removed.id != kept.id)
    try FileManager.default.removeItem(at: f.bin.appending(path: removed.trashName))
    #expect(try await engine.available().map(\.id) == [kept.id])
    #expect(
      !FileManager.default.fileExists(
        atPath: f.journal.appending(path: removed.id.uuidString + ".json").path))
    try await engine.restore(kept.id)
  }

  @Test func categoryAndSingleRowActionsOnlyPreviewCurrentMovableSafeItems() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let phoneID = UUID()
    let device = f.home.appending(
      path: "Library/Developer/CoreSimulator/Devices/" + phoneID.uuidString)
    let cache = device.appending(path: "data/Library/Caches")
    let temp = device.appending(path: "data/tmp")
    let documents = device.appending(path: "data/Documents")
    for path in [cache, temp, documents, f.npm, f.go] { try f.write(path) }
    let root = ScanRoot(
      group: .simulators, title: "Phone", url: device,
      device: SimulatorDevice(id: phoneID, name: "Phone", runtime: "iOS"))
    let measured = try await StorageMeter.measure(root)
    let deviceReport = ScanReport.make(
      roots: [root], results: [root.id: measured], disk: nil,
      extended: true, homeDevice: measured.measuredDevice)
    let report = ScanReport(
      id: UUID(), date: .now, extended: true, free: nil, capacity: nil,
      items: deviceReport.items + [try f.row(f.npm), try f.row(f.go)])
    let candidates = report.safeItemsByCategory(excluding: [f.go.path])
    let simulatorRows = try #require(candidates[ScanGroup.simulators.rawValue])
    #expect(simulatorRows.count == 1)
    let engine = f.store(device: phoneID)
    let states = try await engine.availability(for: report.items, projects: [])
    let selection = report.movableItems(Set(simulatorRows.map(\.id)), states: states, hidden: [])
    let plan = await engine.prepare(items: selection, reportID: report.id, projects: [])
    #expect(Set(plan.targets.map(\.path.path)) == [cache.path, temp.path])
    #expect(try await engine.available().isEmpty)
    #expect(FileManager.default.fileExists(atPath: documents.appending(path: "payload").path))
    let booted = f.store(shutdown: false, device: phoneID)
    let busyStates = try await booted.availability(for: report.items, projects: [])
    #expect(
      report.movableItems(Set(report.items.map(\.id)), states: busyStates, hidden: [f.go.path]).map(
        \.id) == [f.npm.path])
    // A regrowth row identifies one exact cache. It must never expand into the rest of the device.
    let exact = await engine.prepare(
      items: selection, reportID: report.id, projects: [], onlyPath: temp)
    #expect(exact.targets.map(\.path.path) == [temp.path])
    #expect(
      await engine.prepare(items: selection, reportID: report.id, projects: [], onlyPath: documents)
        .targets.isEmpty)
    let result = try await engine.applyAfterTestConfirmation(exact)
    let receipt = try #require(result.moved.first)
    #expect(result.moved.count == 1)
    #expect(
      FileManager.default.fileExists(atPath: cache.path)
        && FileManager.default.fileExists(atPath: documents.path))
    try await engine.restore(receipt.id)
    #expect(try Data(contentsOf: temp.appending(path: "payload")).count == 16384)
  }

  @Test func confirmationIsBoundToOneVisiblePreviewAndCannotBeReused() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    try f.write(f.go)
    let rows = try [f.row(f.npm), f.row(f.go)]
    let store = f.store()
    let reportID = UUID()
    let first = await store.prepare(items: [rows[0]], reportID: reportID, projects: [])
    var preview: TrashPlan? = first
    // A cancelled or closed preview has no authority to move anything.
    preview = nil
    #expect(
      ConfirmedTrashPlan(confirming: first.id, preview: &preview, currentReportID: reportID) == nil)
    let batch = await store.prepare(items: rows, reportID: reportID, projects: [])
    preview = batch
    #expect(
      ConfirmedTrashPlan(confirming: first.id, preview: &preview, currentReportID: reportID) == nil)
    #expect(
      ConfirmedTrashPlan(confirming: batch.id, preview: &preview, currentReportID: UUID()) == nil)
    #expect(try await store.available().isEmpty)
    #expect(rows.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    let accepted = try #require(
      ConfirmedTrashPlan(confirming: batch.id, preview: &preview, currentReportID: reportID))
    #expect(preview == nil)
    #expect(
      ConfirmedTrashPlan(confirming: batch.id, preview: &preview, currentReportID: reportID) == nil)
    let moved = await store.apply(accepted)
    #expect(Set(moved.moved.map(\.original.path)) == [f.npm.path, f.go.path])
  }

  @Test func refocusingReusesOnlyTheDisplaySnapshot() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    let row = try f.row(f.npm)
    let engine = f.store()
    let id = UUID()
    #expect(try await engine.availability(for: [row], projects: [], reportID: id)[row.id] == .ready)
    let prepared = await engine.prepare(items: [row], reportID: id, projects: [])
    try FileManager.default.linkItem(
      at: f.npm.appending(path: "payload"), to: f.home.appending(path: "outside"))
    // Reopening Storage reuses its inspection, but neither preview nor apply can trust it.
    #expect(try await engine.availability(for: [row], projects: [], reportID: id)[row.id] == .ready)
    #expect(await engine.prepare(items: [row], reportID: id, projects: []).targets.isEmpty)
    #expect(try await engine.applyAfterTestConfirmation(prepared).moved.isEmpty)
    #expect(
      try await engine.availability(for: [row], projects: [], reportID: UUID())[row.id] != .ready)
    #expect(try Data(contentsOf: f.npm.appending(path: "payload")).count == 16384)
    try FileManager.default.moveItem(at: f.npm, to: f.home.appending(path: "old-cache"))
    let reopened = UUID()
    #expect(
      try await engine.availability(for: [row], projects: [], reportID: reopened)[row.id] != .ready)
    try f.write(f.npm)
    #expect(
      try await engine.availability(for: [row], projects: [], reportID: reopened)[row.id] == .ready)
  }

  @Test func activePackageToolsBlockPreviewAndMoveEvenAfterAnIdleCheck() async throws {
    actor Running {
      var busy = false
      func start() { busy = true }
      func isIdle() -> Bool { !busy }
    }
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    try f.write(f.go)
    let running = Running()
    let engine = CacheTrash(
      home: f.home, journal: f.journal, packageIdle: { _ in await running.isIdle() })
    let rows = try [f.row(f.npm), f.row(f.go)]
    let id = UUID()
    let approved = await engine.prepare(items: rows, reportID: id, projects: [])
    #expect(approved.targets.count == 2)
    await running.start()
    let states = try await engine.availability(for: rows, projects: [], reportID: id)
    #expect(rows.allSatisfy { states[$0.id] != .ready })
    #expect(await engine.prepare(items: rows, reportID: id, projects: []).targets.isEmpty)
    #expect(try await engine.applyAfterTestConfirmation(approved).moved.isEmpty)
    #expect(rows.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    let unknown = CacheTrash(
      home: f.home, journal: f.journal, packageIdle: { _ in throw CocoaError(.fileReadUnknown) })
    #expect(await unknown.prepare(items: rows, reportID: id, projects: []).targets.isEmpty)
  }

  @Test func appCacheRechecksUseAndContentsAndCanRestore() async throws {
    actor Running {
      var file: String?
      func open(_ path: String?) { file = path }
      func listing() -> String { "p73\nn" + (file ?? "/bin/sh") + "\n" }
    }
    let f = try Fixture()
    defer { f.finish() }
    let running = Running()
    let engine = CacheTrash(home: f.home, journal: f.journal, developmentUse: {
      try await DevelopmentCacheUse(processList: "73 1 \(getuid()) /bin/sh",
        openFiles: running.listing())
    })
    let browser = f.home.appending(path: "Library/Application Support/Chromium")
    let cache = browser.appending(path: "Default/Cache")
    try f.write(cache.appending(path: "Cache_Data"))
    try f.write(browser.appending(path: "Default/Service Worker/CacheStorage"))
    let marker = browser.appending(path: "Local State")
    try Data("{}".utf8).write(to: marker)
    var row = try f.row(cache, category: ScanGroup.appCaches.rawValue)
    row.profile = .appCache
    let id = UUID()
    let plan = await engine.prepare(items: [row], reportID: id, projects: [])
    #expect(plan.targets.count == 1)

    await running.open(cache.appending(path: "Cache_Data/payload").path)
    let availability = try await engine.availability(for: [row], projects: [], reportID: id)
    #expect(availability[row.id] != .ready)
    #expect(try await engine.applyAfterTestConfirmation(plan).moved.isEmpty)

    await running.open(nil)
    try FileManager.default.removeItem(at: marker)
    #expect(await engine.prepare(items: [row], reportID: id, projects: []).targets.isEmpty)
    try Data("{}".utf8).write(to: marker)
    let offline = cache.appending(path: "Cache_Data/IndexedDB")
    try f.write(offline)
    #expect(await engine.prepare(items: [row], reportID: id, projects: []).targets.isEmpty)
    try FileManager.default.removeItem(at: offline)

    let fresh = await engine.prepare(items: [row], reportID: id, projects: [])
    let moved = try await engine.applyAfterTestConfirmation(fresh)
    let receipt = try #require(moved.moved.first)
    #expect(FileManager.default.fileExists(atPath: browser.appending(path: "Default/Service Worker").path))
    _ = try await engine.restore(receipt.id)
    #expect(FileManager.default.fileExists(atPath: cache.path))
  }

  @Test func packageProcessListingDistinguishesCommandsAndNodeScripts() {
    for busy in [
      "npm install", "npx", "/opt/homebrew/bin/npm ci",
      "node /Tools With Spaces/npm/bin/npm-cli.js ci",
      "/opt/homebrew/bin/node /tools/npx-cli.js install", "node npm-cli.js ci",
    ] {
      #expect(!PackageTool.npm.isIdle(in: "/sbin/launchd\n" + busy + "\n/bin/zsh"))
    }
    for busy in ["/usr/local/go/bin/go build ./...", "go test", "/tools/go1.24.3 build"] {
      #expect(!PackageTool.go.isIdle(in: busy))
    }
    let unrelated =
      "/sbin/launchd\nnode /tmp/npm-notes.js\n/usr/local/bin/gofmt\n/usr/bin/cat /tmp/go /tmp/npm"
    #expect(PackageTool.npm.isIdle(in: unrelated))
    #expect(PackageTool.go.isIdle(in: unrelated))
    #expect(!PackageTool.go.isIdle(in: ""))
  }

  @Test func damagedReceiptDoesNotHideOtherRestorableCaches() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.go)
    let engine = f.store()
    let plan = await engine.prepare(items: [try f.row(f.go)], reportID: UUID(), projects: [])
    let receipt = try #require(try await engine.applyAfterTestConfirmation(plan).moved.first)
    let corrupt = f.journal.appending(path: UUID().uuidString + ".json")
    try Data("{".utf8).write(to: corrupt)
    let reopened = f.store()
    #expect(try await reopened.available().map(\.id) == [receipt.id])
    try await reopened.restore(receipt.id)
    #expect(try Data(contentsOf: f.go.appending(path: "payload")).count == 16384)
    #expect(try Data(contentsOf: corrupt) == Data("{".utf8))
  }

  @Test func proposedPlanOnlyCountsWhatTheGUIWouldAllow() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    let phone = UUID()
    let device = f.home.appending(
      path: "Library/Developer/CoreSimulator/Devices/" + phone.uuidString)
    try f.write(device.appending(path: "data/tmp"))
    let rows = try [f.row(device, category: ScanGroup.simulators.rawValue), f.row(f.npm)]
    let report = ScanReport(
      id: UUID(), date: .now, extended: false, free: nil, capacity: nil, items: rows)
    let busy = f.store(shutdown: false, device: phone)
    let states = try await busy.availability(for: rows, projects: [], reportID: report.id)
    #expect(report.plan(target: .max, moveStates: states).map(\.id) == [rows[1].id])
    #expect(report.plan(target: .max, excluding: [rows[1].id], moveStates: states).isEmpty)
    #expect(report.plan(target: .max, moveStates: [:]).isEmpty)
    let shut = f.store(device: phone)
    let refreshed = try await shut.availability(for: rows, projects: [], reportID: report.id)
    #expect(report.plan(target: .max, moveStates: refreshed).count == 2)
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
    let result = try await engine.applyAfterTestConfirmation(plan)
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
    let result = try await engine.applyAfterTestConfirmation(plan)
    #expect(result.moved.count == 1 && result.notices.count == 1)
    #expect(FileManager.default.fileExists(atPath: f.go.path))
    let next = await engine.prepare(items: [rows[1]], reportID: UUID(), projects: [])
    let parent = f.go.deletingLastPathComponent()
    let relocated = f.home.appending(path: "relocated")
    try FileManager.default.moveItem(at: parent, to: relocated)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: relocated)
    #expect(try await engine.applyAfterTestConfirmation(next).moved.isEmpty)
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
    let inactive = f.store(device: UUID(uuidString: device.lastPathComponent))
    let plan = await inactive.prepare(items: [row], reportID: UUID(), projects: [])
    #expect(plan.targets.map(\.path.path) == [cache.path])
    let active = f.store(shutdown: false, device: UUID(uuidString: device.lastPathComponent))
    #expect(await active.prepare(items: [row], reportID: UUID(), projects: []).targets.isEmpty)
    #expect(try await active.applyAfterTestConfirmation(plan).moved.isEmpty)
    #expect(try await inactive.applyAfterTestConfirmation(plan).moved.count == 1)
    #expect(FileManager.default.fileExists(atPath: personal.appending(path: "payload").path))
  }

  @Test func onlyVerifiedIdleProjectIntermediatesMoveAndRestore() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let project = f.home.appending(path: "Projects/Selected")
    let workspace = project.appending(path: "App.xcodeproj")
    try f.write(workspace)
    try Data("project".utf8).write(to: workspace.appending(path: "project.pbxproj"))
    let derived = f.home.appending(path: "Library/Developer/Xcode/DerivedData/App-hash")
    let output = derived.appending(path: ProjectAttribution.intermediates)
    try f.write(output)
    let logs = derived.appending(path: "Logs/Test")
    try f.write(logs, 9)
    try FileManager.default.createSymbolicLink(
      at: output.appending(path: "alias"), withDestinationURL: logs)
    let plist = derived.appending(path: "info.plist")
    func attribute(_ path: String) throws {
      try PropertyListEncoder().encode(["WorkspacePath": path]).write(to: plist, options: .atomic)
    }
    try attribute(workspace.path)
    #expect(try await ProjectAttribution.outputRoots(home: f.home, selected: [output]).isEmpty)
    let roots = try await ProjectAttribution.outputRoots(home: f.home, selected: [])
    let root = try #require(roots.first)
    #expect(roots.count == 1 && root.url == output)
    let measured = try await StorageMeter.measure(root)
    var residual = try #require(ScanRoot.catalog(home: f.home, projects: []).first)
    let total = try await StorageMeter.measure(residual)
    residual.excludedDirectories = ["App-hash/" + ProjectAttribution.intermediates]
    let rest = try await StorageMeter.measure(residual)
    #expect(total.bytes == rest.bytes + measured.bytes && measured.bytes > 0)
    let report = ScanReport.make(
      roots: [root], results: [root.id: measured], disk: nil,
      extended: false, homeDevice: measured.measuredDevice)
    let item = try #require(report.items.first)
    let engine = f.store()
    let states = try await engine.availability(for: [item], projects: [])
    #expect(states[item.id] == .ready)
    let plan = await engine.prepare(items: [item], reportID: report.id, projects: [])
    #expect(plan.targets.map(\.path.path) == [output.path])
    let busy = CacheTrash(home: f.home, journal: f.journal, xcodeIdle: { false })
    #expect(try await busy.availability(for: [item], projects: [project])[item.id] != .ready)
    #expect(try await busy.applyAfterTestConfirmation(plan).moved.isEmpty)
    try attribute(logs.path)
    #expect(try await engine.applyAfterTestConfirmation(plan).moved.isEmpty)
    try attribute(workspace.path)
    let result = try await engine.applyAfterTestConfirmation(plan)
    let receipt = try #require(result.moved.first)
    #expect(try Data(contentsOf: logs.appending(path: "payload")).first == 9)
    #expect(!FileManager.default.fileExists(atPath: output.path))
    try await f.store().restore(receipt.id)
    #expect(try Data(contentsOf: output.appending(path: "payload")).first == 1)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: output.appending(path: "alias").path) == logs.path)
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
    let denied = try await engine.applyAfterTestConfirmation(plan)
    #expect(denied.moved.isEmpty && !denied.notices.isEmpty)
    #expect(FileManager.default.fileExists(atPath: f.npm.path))
  }

  @Test func regrowthSurvivesRestartAndDistinguishesRegenerationFromUndo() async throws {
    let f = try Fixture()
    defer { f.finish() }
    try f.write(f.npm)
    let root = try #require(
      ScanRoot.catalog(home: f.home, projects: []).first { $0.url.path == f.npm.path })
    func scan() async throws -> ScanReport {
      let size = try await StorageMeter.measure(root)
      return .make(
        roots: [root], results: [root.id: size], disk: nil, extended: false,
        homeDevice: size.measuredDevice)
    }
    let before = try await scan()
    let engine = f.store()
    let plan = await engine.prepare(items: before.items, reportID: before.id, projects: [])
    let outcome = try await engine.applyAfterTestConfirmation(plan)
    let receipt = try #require(outcome.moved.first)
    let archive = ScanArchive(file: f.home.appending(path: "history.sqlite"))
    try archive.remember(MovedFolder.from(outcome, plan: plan))
    let reopened = ScanArchive(file: archive.file)
    let moves = try reopened.movedFolders()
    #expect(moves.count == 1)
    #expect(try await MovedFolder.regrown(moves, in: before).isEmpty)
    #expect(try await MovedFolder.regrown(moves, in: scan()).isEmpty)
    try f.write(f.npm, 2)
    let after = try await scan()
    let returned = try await MovedFolder.regrown(moves, in: after)
    #expect(returned.count == 1 && returned.first?.bytes == after.items.first?.bytes)
    // Replacing the generated directory with the original also covers a Finder Put Back.
    try FileManager.default.moveItem(at: f.npm, to: f.home.appending(path: "regenerated"))
    try await engine.restore(receipt.id)
    #expect(try await MovedFolder.regrown(moves, in: scan()).isEmpty)
    try reopened.forgetMove(at: f.npm.path)
    #expect(try reopened.movedFolders().isEmpty)
    try archive.remember(moves)
    try archive.clear()
    #expect(try reopened.movedFolders().isEmpty)
  }

  @Test func oneRecreatedSimulatorCacheDoesNotCountOtherDeviceData() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let udid = UUID()
    let device = f.home.appending(
      path: "Library/Developer/CoreSimulator/Devices/" + udid.uuidString)
    let tracked = device.appending(path: "data/Library/Caches")
    try f.write(tracked)
    try f.write(device.appending(path: "data/Documents"))
    let root = ScanRoot(
      group: .simulators, title: "Test Phone", url: device,
      device: SimulatorDevice(id: udid, name: "Test Phone", runtime: "iOS"))
    func scan() async throws -> ScanReport {
      let size = try await StorageMeter.measure(root)
      return .make(
        roots: [root], results: [root.id: size], disk: nil, extended: false,
        homeDevice: size.measuredDevice)
    }
    let before = try await scan()
    let engine = f.store(device: udid)
    let eligible = before.items.filter { $0.eligibleBytes > 0 }
    let plan = await engine.prepare(items: eligible, reportID: before.id, projects: [])
    let moved = MovedFolder.from(try await engine.applyAfterTestConfirmation(plan), plan: plan)
    #expect(moved.count == 1)
    try f.write(device.appending(path: "data/tmp"), 3)
    #expect(try await MovedFolder.regrown(moved, in: scan()).isEmpty)
    try f.write(tracked, 4)
    let measured = try await StorageMeter.measure(
      .init(group: .simulators, title: "cache", url: tracked))
    #expect(try await MovedFolder.regrown(moved, in: scan()).first?.bytes == measured.bytes)
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
