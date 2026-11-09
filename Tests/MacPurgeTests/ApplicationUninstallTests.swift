import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct ApplicationUninstallTests {
  private struct Fixture {
    let home = URL(fileURLWithPath: "/private/tmp").appending(path: "MacPurge-Uninstall-" + UUID().uuidString)
    let bundleID = "com.example.uninstall-" + UUID().uuidString
    var bundle: URL { home.appending(path: "Applications/Example.app") }
    var cache: URL { home.appending(path: "Library/Caches/" + bundleID) }
    var data: URL { home.appending(path: "Library/Application Support/Example") }
    var preferences: URL { home.appending(path: "Library/Preferences/" + bundleID + ".plist") }
    var helperID: String { bundleID + ".thumbnailer" }
    var app: ApplicationIdentity { .init(name: "Example", bundleID: bundleID, path: bundle.path) }
    var engine: CacheTrash { CacheTrash(home: home, journal: home.appending(path: "receipts"), readVolume: { _ in nil }) }

    init() throws {
      try FileManager.default.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
      try writeBundle(bundle, id: bundleID)
      try writeBundle(bundle.appending(path: "Contents/PlugIns/Thumbnail.appex"), id: helperID)
      try write(cache.appending(path: "blob"))
      try write(data.appending(path: "project"))
      try write(preferences)
    }

    func writeBundle(_ url: URL, id: String) throws {
      let file = url.appending(path: "Contents/Info.plist")
      let contents = try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": id, "CFBundleName": url.deletingPathExtension().lastPathComponent,
      ], format: .xml, options: 0)
      try write(file, contents)
    }

    func write(_ url: URL, _ contents: Data = Data(repeating: 1, count: 8192)) throws {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url)
    }

    func finish() { try? FileManager.default.removeItem(at: home) }

    func confirm(_ targets: [TrashTarget]) throws -> ConfirmedTrashPlan {
      let plan = TrashPlan(reportID: UUID(), targets: targets)
      var preview: TrashPlan? = plan
      #expect(ConfirmedTrashPlan(confirming: plan.id, preview: &preview,
        currentReportID: plan.reportID, acknowledgedReview: true) == nil)
      return try #require(ConfirmedTrashPlan(removingApplication: plan))
    }
  }

  @Test @MainActor func movesOnlySelectedFilesWithoutPreviewAndRecordsUndo() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let engine = f.engine
    let helper = f.home.appending(path: "Library/Application Scripts/" + f.helperID)
    let lookalike = f.home.appending(path: "Library/Caches/" + f.bundleID + ".another-app")
    let shared = f.home.appending(path: "Library/Group Containers/group." + f.bundleID)
    let background = f.home.appending(path: "Library/LaunchAgents/" + f.bundleID + ".plist")
    try f.write(helper.appending(path: "script"))
    try f.write(lookalike.appending(path: "file"))
    try f.write(shared.appending(path: "file"))
    try f.write(background)
    let external = f.home.appending(path: "outside")
    try FileManager.default.linkItem(at: f.cache.appending(path: "blob"), to: external)
    try FileManager.default.createSymbolicLink(at: f.bundle.appending(path: "Contents/link"), withDestinationURL: external)

    let inspection = try await engine.inspectApplication(f.app, projects: [], exclusions: [])
    #expect(inspection.blocker == nil)
    let rows = Dictionary(uniqueKeysWithValues: inspection.rows.map { ($0.id, $0) })
    #expect(rows[helper.path]?.target != nil)
    #expect(rows[background.path]?.target == nil && rows[background.path]?.candidate.blocked != nil)
    #expect(rows[lookalike.path] == nil && rows[shared.path] == nil)
    #expect(Set(inspection.selectableIDs) == [f.bundle.path, f.cache.path, f.data.path, f.preferences.path, helper.path])
    #expect(rows[f.cache.path]?.target?.snapshot.reclaimableBytes == 0)

    let targets = try [f.bundle, f.cache, f.preferences].map { try #require(rows[$0.path]?.target) }
    let defaults = try #require(UserDefaults(suiteName: f.bundleID))
    defer { defaults.removePersistentDomain(forName: f.bundleID) }
    let scan = LiveScan(defaults: defaults, recordsHistory: false, home: f.home, cleanupEngine: engine)
    scan.cleanup.removeApplication(targets, inventoryID: UUID(), scan: scan)
    #expect(!scan.cleanup.busy && scan.cleanup.outcome == nil)
    scan.cleanup.removeApplication(targets, inventoryID: scan.inventoryID, scan: scan)
    #expect(scan.cleanup.applying && scan.cleanup.preview == nil)
    await scan.cleanup.finishCurrentOperation()
    let result = try #require(scan.cleanup.outcome)
    #expect(result.notices.isEmpty)
    #expect(result.moved.map(\.original.path) == targets.map(\.id))
    #expect(FileManager.default.fileExists(atPath: f.data.appending(path: "project").path))
    #expect(FileManager.default.fileExists(atPath: external.path))
    #expect(result.moved.allSatisfy { !FileManager.default.fileExists(atPath: $0.original.path) })
    let saved = try await f.engine.available()
    #expect(saved.count == 3)
    for receipt in saved { _ = try await f.engine.restore(receipt.id) }
    #expect(targets.allSatisfy { FileManager.default.fileExists(atPath: $0.path.path) })
  }

  @Test func keepsRelatedFilesIfBundleChangesAfterListing() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let engine = f.engine
    let inspected = try await engine.inspectApplication(f.app, projects: [], exclusions: [])
    let targets = try [f.bundle, f.cache].map { url in
      try #require(inspected.rows.first(where: { $0.id == url.path })?.target)
    }
    try f.write(f.bundle.appending(path: "Contents/new-resource"))
    let result = await engine.apply(try f.confirm(targets))
    #expect(result.moved.isEmpty && result.notices.count == 2)
    #expect(FileManager.default.fileExists(atPath: f.bundle.path))
    #expect(FileManager.default.fileExists(atPath: f.cache.path))
  }

  @Test func protectsExclusionsProjectsOtherCopiesAndSystemApps() async throws {
    let f = try Fixture()
    defer { f.finish() }
    let engine = f.engine
    let protected = try await engine.inspectApplication(f.app,
      projects: [f.data], exclusions: [f.cache.appending(path: "blob")])
    for path in [f.cache.path, f.data.path] {
      let row = try #require(protected.rows.first { $0.id == path })
      #expect(row.target == nil && row.candidate.blocked != nil)
    }
    try f.writeBundle(f.home.appending(path: "Applications/Example Beta.app"), id: f.bundleID)
    let duplicate = try await engine.inspectApplication(f.app, projects: [], exclusions: [])
    #expect(duplicate.rows.compactMap(\.target).map(\.id) == [f.bundle.path])
    let system = ApplicationIdentity(name: "Mail", bundleID: "com.apple.mail", path: "/System/Applications/Mail.app")
    let systemResult = try await engine.inspectApplication(system, projects: [], exclusions: [])
    #expect(systemResult.rows.count == 1 && systemResult.rows.first?.target == nil && systemResult.blocker != nil)
  }
}
