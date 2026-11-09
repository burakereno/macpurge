import Darwin
import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct FolderExplorerTests {
  @Test func snapshotNavigationAndLargestFilesStayReadOnlyAndDeduplicateHardLinks() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      try helper.write(String(repeating: "x", count: 100_000), "large/video.mp4", home: home)
      try helper.write(String(repeating: "y", count: 20_000), "small/report.pdf", home: home)
      try FileManager.default.linkItem(at: home.appending(path: "large/video.mp4"), to: home.appending(path: "small/alias.mp4"))
      try FileManager.default.createSymbolicLink(at: home.appending(path: "link"), withDestinationURL: home.appending(path: "large"))
      let before = try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted()
      let snapshot = try await FolderExplorer.scan(root: home)
      let largest = snapshot.rows(parent: home.path, mode: .largest, query: "", kind: nil)
      #expect(largest.count == 2 && largest[0].kind == .video)
      #expect(Set(largest.map(\.identity)).count == largest.count)
      #expect(snapshot.entries[home.appending(path: "link").path] == nil && snapshot.skipped == 1)
      #expect(snapshot.entries[home.path]?.bytes == largest.reduce(0) { $0 + ($1.bytes ?? 0) })
      let fileBytes = try #require(snapshot.entries[home.appending(path: "large/video.mp4").path]?.bytes)
      #expect(snapshot.entries[home.appending(path: "large").path]?.bytes == fileBytes)
      #expect((snapshot.entries[home.appending(path: "small").path]?.bytes ?? 0) > fileBytes)
      let small = home.appending(path: "small").path
      #expect(snapshot.rows(parent: small, mode: .largest, query: "alias", kind: .video).count == 1)
      #expect(snapshot.breadcrumbs(to: small).map(\.path) == [home.path, small])
      #expect(snapshot.rows(parent: home.path, mode: .largest, query: "report", kind: .document, limit: 1).first?.name == "report.pdf")
      #expect(try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted() == before)
      #expect(try String(contentsOf: home.appending(path: "small/report.pdf"), encoding: .utf8).count == 20_000)
    }
  }

  @Test func filteringPrecedesLargestLimitAndBrowsingUsesOnlySavedMeasurements() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      try helper.write(String(repeating: "x", count: 100_000), "big.bin", home: home)
      try helper.write(String(repeating: "y", count: 20_000), "nested/keep.pdf", home: home)
      let snapshot = try await FolderExplorer.scan(root: home)
      #expect(snapshot.rows(parent: home.path, mode: .largest, query: "", kind: nil, limit: 1).first?.name == "big.bin")
      #expect(snapshot.rows(parent: home.path, mode: .largest, query: "", kind: .document, limit: 1).first?.name == "keep.pdf")
      try helper.write(String(repeating: "z", count: 200_000), "new.bin", home: home)
      #expect(!snapshot.rows(parent: home.path, mode: .folders, query: "", kind: nil).contains { $0.name == "new.bin" })
      #expect(snapshot.rows(parent: home.path + "-outside", mode: .largest, query: "", kind: nil).isEmpty)
    }
  }

  @Test func sparseAllocationExclusionsAndBudgetsRemainExplicit() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      try helper.write("", "sparse", home: home)
      let handle = try FileHandle(forWritingTo: home.appending(path: "sparse"))
      try handle.truncate(atOffset: 10_000_000); try handle.close()
      try helper.write("omitted", "private/secret", home: home)
      let snapshot = try await ScanExclusions.$current.withValue(.init(paths: [home.appending(path: "private").path])) {
        try await FolderExplorer.scan(root: home)
      }
      let sparse = try #require(snapshot.entries[home.appending(path: "sparse").path])
      #expect(sparse.logicalBytes == 10_000_000 && (sparse.bytes ?? .max) < 10_000_000)
      #expect(snapshot.excluded == 1 && !snapshot.entries.keys.contains { $0.contains("secret") })
      let limited = try await FolderExplorer.scan(root: home, maximumEntries: 1)
      #expect(limited.limited && limited.examined == 1 && limited.entries.count <= 2)
      let timed = try await FolderExplorer.scan(root: home, timeBudget: .zero)
      #expect(timed.limited && timed.examined == 0 && timed.entries[home.path]?.partial == true)
      let shallow = try await FolderExplorer.scan(root: home, maximumDepth: 0)
      #expect(shallow.limited && shallow.examined == 0)
    }
  }

  @Test func excludedAndSymlinkRootsAndCancelledScansCannotExpandScope() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let link = home.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
      await #expect(throws: (any Error).self) { _ = try await FolderExplorer.scan(root: link) }
      await ScanExclusions.$current.withValue(.init(paths: [home.path])) {
        await #expect(throws: (any Error).self) { _ = try await FolderExplorer.scan(root: home) }
      }
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await FolderExplorer.scan(root: home)
      }
      await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    }
  }
}
