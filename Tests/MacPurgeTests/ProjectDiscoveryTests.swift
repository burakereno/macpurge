import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct ProjectDiscoveryTests {
  private struct Fixture {
    let home = URL(filePath: "/private/tmp/macpurge-projects-" + UUID().uuidString)
    let fm = FileManager.default

    @discardableResult func folder(_ path: String) throws -> URL {
      let url = home.appending(path: path)
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    func write(_ path: String, _ count: Int = 8192) throws {
      let url = home.appending(path: path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 65, count: count).write(to: url)
    }

    func seed() throws {
      for path in [
        "Projects/Clients/Site/package.json", "Projects/Clients/Site/node_modules/a/package.json",
        "Projects/Clients/Site/web/package.json", "Projects/Clients/Site/web/.next/cache/file",
        "Projects/Clients/Site/web/.next/server/file", "Projects/App/Package.swift",
        "Projects/App/.build/checkouts/dependency/Package.swift", "Projects/Empty/go.mod",
        "Projects/Clients/Site/samples/Pods/source", "Projects/readme",
      ] { try write(path) }
      try fm.createSymbolicLink(
        at: home.appending(path: "Projects/Alias"),
        withDestinationURL: home.appending(path: "Projects/App"))
      try folder(".Trash")
    }
  }

  @Test @MainActor func selectionToPlanAndUndoPreservesProjectSources() async throws {
    let f = Fixture()
    defer { try? f.fm.removeItem(at: f.home) }
    try f.seed()
    // A dependency manager can hard-link files across the source and output partitions.
    try f.fm.linkItem(
      at: f.home.appending(path: "Projects/Clients/Site/package.json"),
      to: f.home.appending(path: "Projects/Clients/Site/web/.next/server/shared"))
    let suite = UUID().uuidString
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "Journal"))
    let scan = LiveScan(
      defaults: prefs, recordsHistory: false, home: f.home, cleanupEngine: engine,
      localInventory: { _, _, _, _ in [] }, toolInventory: { _, _ in [] })
    let scope = f.home.appending(path: "Projects")
    scan.addProjects([scope])
    await scan.finishCurrentScan()
    try #require(scan.phase == .finished)
    await scan.refreshMoveStates()
    #expect(Set(scan.projectCards.map { $0.url.lastPathComponent }) == ["Site", "App", "Empty"])
    let site = try #require(scan.projectCards.first { $0.url.lastPathComponent == "Site" })
    #expect(
      Set(site.outputs.map(\.title)) == [
        "web/.next/cache", "web/.next/server", "node_modules", "samples/Pods",
      ])
    let server = try #require(site.outputs.first { $0.title == "web/.next/server" })
    let shared = site.url.appending(path: "package.json")
    var info = stat()
    try #require(lstat(shared.path, &info) == 0)
    // Its second hard link is in the project source. Only the server's own file can free space.
    #expect(server.candidateBytes == (server.bytes ?? 0) - Int64(info.st_blocks) * 512)
    #expect(server.reclaimableBytes == server.candidateBytes)
    #expect(site.candidateBytes == site.reclaimableBytes)
    #expect(site.outputs.first { $0.title == "samples/Pods" }?.reclaimableBytes == 0)
    let tree = try await DirectoryMeasurement.measure(scope)
    #expect(scan.groupBytes[.projects] == tree.allocatedBytes)
    let siteTree = try await DirectoryMeasurement.measure(site.url)
    #expect(site.bytes == siteTree.allocatedBytes)
    let report = try #require(scan.report)
    let cache = try #require(site.outputs.first { $0.title == "web/.next/cache" }?.item)
    let modules = try #require(site.outputs.first { $0.title == "node_modules" }?.item)
    let ambiguous = try #require(site.outputs.first { $0.title == "samples/Pods" }?.item)
    #expect(scan.action(for: ambiguous).risk == nil)
    let source = try #require(report.items.first { $0.path == site.id })
    #expect(scan.action(for: source).risk == nil)
    let rows = scan.explicitSelection([cache.id, modules.id, source.id, ambiguous.id], in: report)
    #expect(Set(rows.map(\.id)) == [cache.id, modules.id])
    let plan = await engine.prepare(
      items: rows, reportID: report.id,
      projects: scan.protectedProjects, manual: scan.manualMoves)
    #expect(plan.skipped.isEmpty && plan.needsReview)
    #expect(Set(plan.targets.map(\.path.path)) == [cache.path, modules.path])
    var preview: TrashPlan? = plan
    let confirmed = try #require(
      ConfirmedTrashPlan(
        confirming: plan.id, preview: &preview,
        currentReportID: report.id, acknowledgedReview: true))
    let outcome = await engine.apply(confirmed)
    #expect(outcome.notices.isEmpty && outcome.moved.count == 2)
    await scan.refreshAfterCleanup(outcome.moved, restored: false, disk: nil)
    let after = try #require(scan.projectCards.first { $0.id == site.id })
    #expect(Set(after.outputs.map(\.title)) == ["web/.next/server", "samples/Pods"])
    #expect(f.fm.fileExists(atPath: site.url.appending(path: "package.json").path))
    #expect(f.fm.fileExists(atPath: site.url.appending(path: "web/.next/server/file").path))
    // Rescan with the outputs absent, then undo: each restored boundary must return once.
    scan.startQuick()
    await scan.finishCurrentScan()
    for receipt in outcome.moved {
      let restored = try await engine.restore(receipt.id)
      await scan.refreshAfterCleanup([restored], restored: true, disk: nil)
    }
    let again = try #require(scan.projectCards.first { $0.id == site.id })
    #expect(again.bytes == site.bytes)
    #expect(Set(again.outputs.map(\.title)) == Set(site.outputs.map(\.title)))
  }

  @Test func selectedRepoStaysOneProjectAndPermissionExpiresWithManifest() async throws {
    let f = Fixture()
    defer { try? f.fm.removeItem(at: f.home) }
    try f.seed()
    let site = f.home.appending(path: "Projects/Clients/Site")
    let inventory = try await ProjectDiscovery.discover([
      .init(group: .projects, title: "Site", url: site, profile: .project)
    ])
    #expect(inventory.projects.map(\.path) == [site.path])
    let root = try #require(inventory.roots.first { $0.url.lastPathComponent == "node_modules" })
    let size = try await StorageMeter.measure(root)
    let rows = ScanReport.makeItems(
      roots: [root], results: [root.id: size], homeDevice: size.measuredDevice)
    let manual = await ManualReview.candidates(
      roots: [root], results: [root.id: size],
      rows: rows, home: f.home, projects: [site])
    #expect(manual.moves.count == 1)
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "Journal"))
    let outside = await engine.prepare(
      items: rows, reportID: UUID(), projects: [], manual: manual.moves)
    #expect(outside.targets.isEmpty)
    try f.fm.removeItem(at: site.appending(path: "package.json"))
    let stale = await engine.prepare(
      items: rows, reportID: UUID(), projects: [site], manual: manual.moves)
    #expect(stale.targets.isEmpty && !stale.skipped.isEmpty)
  }
  @Test @MainActor func buildContentsShowLossesAndDeleteOnlyTheChosenOutputDirectly() async throws {
    let f = Fixture()
    defer { try? f.fm.removeItem(at: f.home) }
    for path in [
      "App/Package.swift", "App/Sources/main.swift",
      "App/.build/install-backup/Previous.app/binary",
      "App/.build/Release.xcarchive/symbols",
      "App/.build/DerivedData/Build/Intermediates.noindex/object.o",
      "App/.build/DerivedData/Build/Products/App",
      "App/.build/DerivedData/Build/Products/App.dSYM/symbols",
      "App/.build/DerivedData/ModuleCache.noindex/module",
      "App/.build/performance.trace/record", "App/.build/README.txt",
    ] { try f.write(path) }
    try f.folder(".Trash")
    let suite = UUID().uuidString
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "Journal"))
    let scan = LiveScan(
      defaults: prefs, recordsHistory: false, home: f.home, cleanupEngine: engine,
      localInventory: { _, _, _, _ in [] }, toolInventory: { _, _ in [] })
    let app = f.home.appending(path: "App")
    scan.addProjects([app])
    await scan.finishCurrentScan()
    await scan.refreshMoveStates()
    let card = try #require(scan.projectCards.first)
    let group = try #require(card.outputGroups.first { $0.isBuildFolder })
    let direct = try await DirectoryMeasurement.measure(app.appending(path: ".build"))
    let project = try await DirectoryMeasurement.measure(app)
    #expect(group.bytes == direct.allocatedBytes)
    #expect(card.bytes == project.allocatedBytes)
    let object = try #require(card.outputs.first { $0.path.hasSuffix("/Intermediates.noindex") })
    let backup = try #require(card.outputs.first { $0.path.hasSuffix("/install-backup") })
    let archive = try #require(card.outputs.first { $0.path.hasSuffix("/Release.xcarchive") })
    let products = try #require(card.outputs.first { $0.path.hasSuffix("/Build/Products") })
    #expect(!products.isReproducible) // Old dSYMs must never be swept up by the generated-files button.
    let readme = try #require(card.outputs.first { $0.path.hasSuffix("/README.txt") })
    #expect(object.isReproducible && !backup.isReproducible && !archive.isReproducible)
    #expect(ProjectOutputKind.classify(backup.path) == .backup)
    #expect(ProjectOutputKind.classify(archive.path) == .archive)
    #expect(!ProjectOutput.effect(URL(fileURLWithPath: backup.path)).isEmpty)
    let row = try #require(object.item)
    // Exercise the same direct cleanup entry point as each project's Trash button.
    scan.cleanup.prepare([row], scan: scan, explicit: true)
    await scan.cleanup.finishCurrentOperation()
    let preview = try #require(scan.cleanup.preview)
    #expect(!preview.needsReview)
    #expect(preview.targets.map(\.path.path) == [object.path])
    scan.cleanup.confirmMove(preview.id, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    let outcome = try #require(scan.cleanup.outcome)
    #expect(outcome.moved.count == 1 && outcome.notices.isEmpty)
    for preserved in [
      "Sources/main.swift", ".build/install-backup/Previous.app/binary",
      ".build/Release.xcarchive/symbols", ".build/README.txt",
      ".build/DerivedData/Build/Products/App.dSYM/symbols",
    ] {
      #expect(f.fm.fileExists(atPath: app.appending(path: preserved).path))
    }
    let review = await engine.prepare(
      items: [
        try #require(backup.item), try #require(archive.item),
        try #require(readme.item),
      ], reportID: try #require(scan.report).id,
      projects: scan.protectedProjects, manual: scan.manualMoves)
    #expect(review.needsReview && review.targets.count == 3)
    #expect(review.targets.contains { $0.path.path == readme.path && $0.review?.file == true })
    scan.startQuick()
    await scan.finishCurrentScan()
    scan.cleanup.restore(outcome.moved[0], scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(f.fm.fileExists(atPath: object.path))
    #expect(scan.projectCards.first?.outputGroups.first { $0.isBuildFolder }?.bytes == group.bytes)
  }

}
