import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct ControlReleaseTests {
  private func fixture(_ test: (URL) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(
      path: "macpurge-control-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await test(root)
  }

  @Test func previewAndExportExcludeReviewAndOtherVolumes() async throws {
    try await fixture { base in
      let cache = ScanRoot(
        group: .packages, title: "dependency", url: base.appending(path: "cache"),
        profile: .npmCache)
      let project = ScanRoot(
        group: .projects, title: "personal", url: base.appending(path: "work"), profile: .project)
      let second = ScanRoot(
        group: .packages, title: "external", url: base.appending(path: "external"),
        profile: .goBuildCache)
      let first = RootSize(bytes: 8_000_000, measuredDevice: 3, sharedLinkBytes: 2_000_000)
      let report = ScanReport.make(
        roots: [cache, project, second],
        results: [
          cache.id: first, project.id: RootSize(bytes: 32_000_000, measuredDevice: 3),
          second.id: RootSize(bytes: 40_000_000, measuredDevice: 4),
        ], disk: nil, extended: true, homeDevice: 3)
      let selected = report.plan(
        target: 20_000_000,
        moveStates: Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, .ready) }))
      #expect(selected.map(\.name) == ["dependency"])
      #expect(selected.first?.eligibleBytes == 6_000_000)
      let redacted = String(decoding: try report.export(), as: UTF8.self)
      #expect(!redacted.contains("private/tmp") && !redacted.contains("\"path\""))
      #expect(try report.export(includePaths: true).count > report.export().count)
      let archive = ScanArchive(file: base.appending(path: "history.sqlite"))
      try archive.save(report)
      #expect(try archive.read().first?.items == report.items)
      try archive.clear()
      #expect(try archive.read().isEmpty)
    }
  }

  @Test func watchedRootsInvalidateForDeepWritesWithoutRootMtimeChanges() async throws {
    try await fixture { dir in
      let nested = dir.appending(path: "folder/deeper")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let file = nested.appending(path: "live")
      try Data(repeating: 1, count: 4096).write(to: file)
      let root = ScanRoot(group: .projects, title: "fixture", url: dir)
      let cache = MeasurementCache()
      await cache.configure([root])
      let old = await cache.ticket(root)
      let measured = try await StorageMeter.measure(root)
      await cache.store(measured, for: root, before: old)
      let initial = await cache.cached(root, await cache.ticket(root))
      if old == nil { #expect(initial == nil) } else { #expect(initial?.bytes == measured.bytes) }
      try Data(repeating: 3, count: 64 * 1024).write(to: file)
      #expect(await cache.cached(root, await cache.ticket(root)) == nil)
      await cache.stop()
    }
  }

  @Test func commandTimeoutAndMissingExecutableAreDistinctFromAnEmptyInventory() async throws {
    await #expect(throws: InventoryCommand.Failure.timedOut) {
      _ = try await InventoryCommand.output("/bin/sleep", ["3"], timeout: .milliseconds(60))
    }
    await #expect(throws: (any Error).self) {
      _ = try await InventoryCommand.output("/missing/macpurge/tool", [])
    }
  }

  @Test func dockerUsagePartitionsActualTotalsForLegacyAndCurrentEngines() throws {
    let socket = URL(fileURLWithPath: "/test/socket")
    let current =
      #"{"ImageUsage":{"TotalSize":1000,"Reclaimable":0,"Items":[{"Id":"a","Size":800,"SharedSize":200}]},"ContainerUsage":{"TotalSize":40,"Items":[{"ImageID":"a","SizeRw":40,"Labels":{"com.docker.compose.project":"app","com.docker.compose.project.working_dir":"/p"}}]},"VolumeUsage":{"TotalSize":200,"Items":[{"Name":"v","Labels":{"com.docker.compose.project":"app"},"UsageData":{"RefCount":1,"Size":50}}]},"BuildCacheUsage":{"TotalSize":10}}"#
    let legacy =
      #"{"LayersSize":1000,"Containers":[{"ImageID":"b","SizeRw":40}],"Volumes":[{"Name":"v","UsageData":{"Size":200}}],"BuildCache":[{"Size":90,"Shared":true},{"Size":10,"Shared":false}]}"#
    for json in [current, legacy] {
      let rows = try ComposeInventory.rows(data: Data(json.utf8), socket: socket)
      let sizes = rows.compactMap { row -> Int64? in
        if case .report(let n) = row.source { return n }
        return nil
      }
      #expect(sizes.reduce(0, +) == 1250)
      #expect(rows.count == sizes.count)
      if json == current {
        #expect(rows.first { $0.title == "Compose · app" }?.source == .report(600))
        #expect(rows.first { $0.title == "Docker · Images" }?.source == .report(400))
      }
    }
  }

  @Test func composeSharesAreNotAssignedToTheWrongProject() throws {
    let json =
      #"{"Images":[{"Id":"a","Size":100,"SharedSize":90},{"Id":"b","Size":200,"SharedSize":30}],"Containers":[{"ImageID":"a","Labels":{"com.docker.compose.project":"one","com.docker.compose.project.working_dir":"/test/one"}},{"ImageID":"a","Labels":{"com.docker.compose.project":"two","com.docker.compose.project.working_dir":"/test/two"}},{"ImageID":"b","Labels":{"com.docker.compose.project":"two","com.docker.compose.project.working_dir":"/test/two"}}]}"#
    let rows = try ComposeInventory.rows(
      data: Data(json.utf8), socket: URL(fileURLWithPath: "/test/socket"))
    let compose = rows.filter { $0.title.hasPrefix("Compose") }
    #expect(compose.count == 1 && compose.first?.source == .report(170))
    #expect(compose.first?.title.contains("two") == true)
  }

  @Test func ollamaSharedBlobsAreCountedOnlyOnce() async throws {
    try await fixture { base in
      let fm = FileManager.default
      let blobs = base.appending(path: "blobs")
      try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
      let digest = String(repeating: "a", count: 64)
      try Data(repeating: 2, count: 8192).write(to: blobs.appending(path: "sha256-" + digest))
      for name in ["m1", "m2"] {
        let path = base.appending(path: "manifests/local/" + name)
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
          "layers": [["digest": "sha256:" + digest]]
        ])
        try data.write(to: path.appending(path: "latest"))
      }
      let rows = try await ModelInventory.ollama(at: base)
      #expect(rows.filter { $0.source == .allocation(0) }.count == 2)
      #expect(rows.filter { $0.title.contains("paylaşılan") }.count == 1)
    }
  }

  @Test func mapsOnlyVerifiedWorkspacePathsToSelectedRoots() {
    let root = URL(fileURLWithPath: "/work/Atlas")
    #expect(
      ProjectAttribution.owningRoot(workspace: "/work/Atlas/App.xcworkspace", selected: [root])
        == root)
    #expect(
      ProjectAttribution.owningRoot(
        workspace: "/work/AtlasBackup/App.xcworkspace", selected: [root]) == nil)
  }
}
