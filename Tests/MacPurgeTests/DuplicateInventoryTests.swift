import Darwin
import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct DuplicateInventoryTests {
  @Test func clonedFixtureCopiesDoNotPromiseRecoveredSpaceAndHashingIsBounded() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let folder = home.appending(path: "Documents")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let original = folder.appending(path: "a.bin"), copy = folder.appending(path: "b.bin")
      try Data(repeating: 0x5a, count: 2 * 1024 * 1024).write(to: original)
      // clonefile is unavailable on some non-APFS test volumes.
      guard clonefile(original.path, copy.path, 0) == 0 else {
        #expect(errno == ENOTSUP || errno == EXDEV)
        return
      }
      let report = try await DuplicateInventory.scan(root: folder, home: home)
      let group = try #require(report.groups.first)
      #expect(group.files.count == 2 && group.files.allSatisfy { $0.mayShareBlocks != false })
      #expect(group.estimatedRecovery == 0)
      try FileManager.default.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
      let plan = try await report.plan(selected: [copy.path], engine: CacheTrash(home: home, journal: home.appending(path: "receipts")))
      #expect(plan.targets.count == 1 && plan.reclaimableBytes == 0)
      let limited = try await DuplicateInventory.scan(root: folder, home: home, hashBudget: 65536)
      #expect(limited.limited && limited.groups.isEmpty)
      #expect(throws: (any Error).self) { _ = try FileComparison.proof(original, expectedBytes: 1) }
      #expect(try !FileComparison.equal(original, copy, expectedBytes: 1))
    }
  }

  @Test func reviewedFixtureCopyMovesToTrashAndRestores() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      for name in ["a", "b"] { try helper.write("same contents", "Documents/" + name, home: home) }
      try FileManager.default.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
      let report = try await DuplicateInventory.scan(root: home.appending(path: "Documents"), home: home, minimumBytes: 1)
      let files = try #require(report.groups.first?.files)
      let engine = CacheTrash(home: home, journal: home.appending(path: "receipts"))
      var preview: TrashPlan? = try await report.plan(selected: [files[1].path], engine: engine)
      let confirmed = try #require(ConfirmedTrashPlan(confirming: preview!.id, preview: &preview,
        currentReportID: report.id, acknowledgedReview: true))
      let result = await engine.apply(confirmed)
      let receipt = try #require(result.moved.first)
      #expect(result.moved.count == 1)
      #expect(try String(contentsOfFile: files[0].path, encoding: .utf8) == "same contents")
      _ = try await engine.restore(receipt.id)
      #expect(try String(contentsOfFile: files[1].path, encoding: .utf8) == "same contents")
    }
  }
  @Test func findsOnlyIdenticalIndependentFilesAndKeepsOneCopy() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      for name in ["a", "b", "c"] { try helper.write("same contents", "Documents/" + name, home: home) }
      try helper.write("different!!!!", "Documents/different", home: home)
      try helper.write("same contents", "Documents/node_modules/ignored", home: home)
      try helper.write("same contents", "Documents/.hidden/ignored", home: home)
      try FileManager.default.linkItem(at: home.appending(path: "Documents/a"), to: home.appending(path: "Documents/hardlink"))
      let folder = home.appending(path: "Documents")
      let before = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
      let report = try await DuplicateInventory.scan(root: folder, home: home, minimumBytes: 1)
      let group = try #require(report.groups.first)
      #expect(report.groups.count == 1 && group.files.count == 3)
      #expect(!group.files.contains { $0.path.contains("ignored") })
      let bin = home.appending(path: ".Trash")
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      let engine = CacheTrash(home: home, journal: home.appending(path: "receipts"))
      await #expect(throws: (any Error).self) {
        _ = try await report.plan(selected: Set(group.files.map(\.path)), engine: engine)
      }
      let target = try #require(group.files.first { $0.links == 1 })
      let plan = try await report.plan(selected: [target.path], engine: engine)
      #expect(plan.targets.count == 1 && plan.needsReview)
      #expect(try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted() == before)
      #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
    }
  }

  @Test func changedSurvivorBlocksAConfirmedMoveAndLeavesSourcesUntouched() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      for name in ["a", "b"] { try helper.write("same contents", "Documents/" + name, home: home) }
      try FileManager.default.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
      let report = try await DuplicateInventory.scan(root: home.appending(path: "Documents"), home: home, minimumBytes: 1)
      let files = try #require(report.groups.first?.files)
      let engine = CacheTrash(home: home, journal: home.appending(path: "receipts"))
      var preview: TrashPlan? = try await report.plan(selected: [files[1].path], engine: engine)
      let confirmation = try #require(ConfirmedTrashPlan(confirming: preview!.id, preview: &preview,
        currentReportID: report.id, acknowledgedReview: true))
      try Data("changed value".utf8).write(to: URL(fileURLWithPath: files[0].path))
      let outcome = await engine.apply(confirmation)
      #expect(outcome.moved.isEmpty && !outcome.notices.isEmpty)
      #expect(try String(contentsOfFile: files[1].path, encoding: .utf8) == "same contents")
    }
  }

  @Test func cancellationAndSymlinkRootsDoNotProduceAuthority() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      try helper.write("content", "Documents/file", home: home)
      try FileManager.default.createSymbolicLink(at: home.appending(path: "alias"), withDestinationURL: home.appending(path: "Documents"))
      await #expect(throws: (any Error).self) {
        _ = try await DuplicateInventory.scan(root: home.appending(path: "alias"), home: home, minimumBytes: 1)
      }
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await DuplicateInventory.scan(root: home.appending(path: "Documents"), home: home, minimumBytes: 1)
      }
      await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
  }
}
