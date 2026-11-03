import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

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
        simulatorStates: { device.map { [$0: shutdown ? "Shutdown" : "Booted"] } ?? [:] },
        xcodeIdle: { true })
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
    let inactive = f.store(device: UUID(uuidString: device.lastPathComponent))
    let plan = await inactive.prepare(items: [row], reportID: UUID(), projects: [])
    #expect(plan.targets.map(\.path.path) == [cache.path])
    let active = f.store(shutdown: false, device: UUID(uuidString: device.lastPathComponent))
    #expect(await active.prepare(items: [row], reportID: UUID(), projects: []).targets.isEmpty)
    #expect(await active.apply(plan).moved.isEmpty)
    #expect(await inactive.apply(plan).moved.count == 1)
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
    #expect(try await ProjectAttribution.outputRoots(home: f.home, selected: [logs]).isEmpty)
    let roots = try await ProjectAttribution.outputRoots(home: f.home, selected: [project])
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
    #expect(await engine.prepare(items: [item], reportID: report.id, projects: []).targets.isEmpty)
    let states = try await engine.availability(for: [item], projects: [project])
    #expect(states[item.id] == .ready)
    let plan = await engine.prepare(items: [item], reportID: report.id, projects: [project])
    #expect(plan.targets.map(\.path.path) == [output.path])
    let busy = CacheTrash(home: f.home, journal: f.journal, xcodeIdle: { false })
    #expect(try await busy.availability(for: [item], projects: [project])[item.id] != .ready)
    #expect(await busy.apply(plan).moved.isEmpty)
    try attribute(logs.path)
    #expect(await engine.apply(plan).moved.isEmpty)
    try attribute(workspace.path)
    let result = await engine.apply(plan)
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
    let denied = await engine.apply(plan)
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
    let outcome = await engine.apply(plan)
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
    let moved = MovedFolder.from(await engine.apply(plan), plan: plan)
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
