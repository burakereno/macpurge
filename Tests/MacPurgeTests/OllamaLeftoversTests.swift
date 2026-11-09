import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct OllamaLeftoversTests {
  private let digest = String(repeating: "a", count: 64)
  private let orphan = String(repeating: "b", count: 64)

  func store(_ home: URL) throws -> URL {
    let helper = DeveloperDataInventoryTests()
    try helper.write("referenced", ".ollama/models/blobs/sha256-" + digest, home: home)
    try helper.write("orphan", ".ollama/models/blobs/sha256-" + orphan, home: home)
    try helper.write("partial", ".ollama/models/blobs/sha256-" + orphan + "-partial-0", home: home)
    try helper.write("{\"layers\":[{\"digest\":\"sha256:\(digest)\"}]}", ".ollama/models/manifests/registry/library/model/latest", home: home)
    let root = home.appending(path: ".ollama/models")
    for name in ["sha256-" + orphan, "sha256-" + orphan + "-partial-0"] {
      try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-5 * 86400)], ofItemAtPath: root.appending(path: "blobs/" + name).path)
    }
    return root
  }

  @Test func onlyCompleteManifestGraphsProduceSeparateLeftoversWithoutDoubleCounting() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let root = try store(home)
      let graph = try OllamaLeftovers.inspect(root: root)
      #expect(graph.complete && graph.leftovers.count == 2)
      #expect(!graph.leftovers.contains { $0.url.lastPathComponent == "sha256-" + digest })
      let rows = try await ModelInventory.ollama(at: root)
      #expect(rows.filter { $0.source == .file }.count == 2)
      let whole = try await StorageMeter.measure(.init(group: .models, title: "store", url: root.appending(path: "blobs")))
      var total: Int64 = 0
      for row in rows {
        let measured = try await StorageMeter.measure(row)
        total += measured.bytes
      }
      #expect(total == whole.bytes)
    }
  }

  @Test func brokenExcludedOrSymlinkedManifestsNeverAuthorizeRemoval() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let root = try store(home)
      let manifest = root.appending(path: "manifests/registry/library/model/latest")
      try Data("broken".utf8).write(to: manifest)
      #expect(try OllamaLeftovers.inspect(root: root).complete == false)
      let result = try ScanExclusions.$current.withValue(.init(paths: [root.appending(path: "manifests").path])) {
        try OllamaLeftovers.inspect(root: root)
      }
      #expect(!result.complete && result.leftovers.isEmpty)
    }
  }

  @Test func newReferencesOrActiveOwnerBlockAReviewedFixtureMove() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let root = try store(home)
      try FileManager.default.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
      let rows = try await ModelInventory.ollama(at: root)
      var sizes: [String: RootSize] = [:]
      for row in rows { sizes[row.id] = try await StorageMeter.measure(row) }
      let report = ScanReport.make(roots: rows, results: sizes, disk: nil, extended: true, homeDevice: sizes.values.first?.measuredDevice)
      let manual = await ManualReview.candidates(roots: rows, results: sizes, rows: report.items, home: home, projects: [])
      let item = try #require(report.items.first { $0.path.hasSuffix("sha256-" + orphan) })
      #expect(manual.moves[item.id]?.ollama != nil)
      let active = CacheTrash(home: home, journal: home.appending(path: "receipts"), ollamaIdle: { false })
      let denied = await active.prepare(items: [item], reportID: report.id, projects: [], manual: manual.moves)
      #expect(denied.targets.isEmpty)
      let idle = CacheTrash(home: home, journal: home.appending(path: "receipts"), ollamaIdle: { true })
      var plan: TrashPlan? = await idle.prepare(items: [item], reportID: report.id, projects: [], manual: manual.moves)
      #expect(plan?.targets.count == 1)
      let confirmed = try #require(ConfirmedTrashPlan(confirming: plan!.id, preview: &plan, currentReportID: report.id, acknowledgedReview: true))
      let manifest = root.appending(path: "manifests/registry/library/model/latest")
      try Data("{\"layers\":[{\"digest\":\"sha256:\(orphan)\"}]}".utf8).write(to: manifest)
      let result = await idle.apply(confirmed)
      #expect(result.moved.isEmpty)
      #expect(FileManager.default.fileExists(atPath: item.path))
    }
  }
  @Test func verifiedOldFixtureBlobCanBeRestoredAndRecentBlobsStayInspectionOnly() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let root = try store(home)
      try FileManager.default.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
      try Data("recent".utf8).write(to: root.appending(path: "blobs/sha256-" + String(repeating: "c", count: 64)))
      let roots = try await ModelInventory.ollama(at: root)
      #expect(roots.first { $0.url.lastPathComponent.hasSuffix(String(repeating: "c", count: 64)) }?.evidence?.inspectionOnly == true)
      var sizes: [String: RootSize] = [:]
      for row in roots { sizes[row.id] = try await StorageMeter.measure(row) }
      let report = ScanReport.make(roots: roots, results: sizes, disk: nil, extended: true, homeDevice: sizes.values.first?.measuredDevice)
      let reviews = await ManualReview.candidates(roots: roots, results: sizes, rows: report.items, home: home, projects: [])
      let item = try #require(report.items.first { $0.path.hasSuffix("sha256-" + orphan) })
      let engine = CacheTrash(home: home, journal: home.appending(path: "receipts"), ollamaIdle: { true })
      var preview: TrashPlan? = await engine.prepare(items: [item], reportID: report.id, projects: [], manual: reviews.moves)
      let confirmed = try #require(ConfirmedTrashPlan(confirming: preview!.id, preview: &preview, currentReportID: report.id, acknowledgedReview: true))
      let result = await engine.apply(confirmed)
      let receipt = try #require(result.moved.first)
      _ = try await engine.restore(receipt.id)
      #expect(try String(contentsOfFile: item.path, encoding: .utf8) == "orphan")
    }
  }
  @Test func symlinkedManifestAndMissingManifestDirectoriesAreNeverComplete() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let root = try store(home)
      try FileManager.default.createSymbolicLink(at: root.appending(path: "manifests/registry/library/model/alias"),
        withDestinationURL: root.appending(path: "manifests/registry/library/model/latest"))
      #expect(try OllamaLeftovers.inspect(root: root).complete == false)
      #expect(try OllamaLeftovers.inspect(root: home.appending(path: "missing")).complete == false)
    }
  }
}
