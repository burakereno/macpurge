import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct DownloadsInventoryTests {
  @Test func sparseRepeatDownloadsUseAllocatedSpaceWithoutWritingTheirContents() async throws {
    try await DeveloperDataInventoryTests().fixture { home in
      let folder = home.appending(path: "Downloads")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for name in ["sparse.bin", "sparse (1).bin"] {
        let file = folder.appending(path: name)
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 2 * 1024 * 1024)
        try handle.close()
      }
      let roots = try DownloadsInventory.discover(home: home, applications: [],
        volumes: ScanVolumes(home: home, projects: []), includeProtected: true)
      let copy = try #require(roots.first { $0.evidence?.finding == .duplicateDownload })
      #expect(copy.evidence?.inspectionOnly == true)
      let measured = try await StorageMeter.measure(copy)
      #expect(measured.bytes < 2 * 1024 * 1024)
      #expect(try FileComparison.proof(copy.url).logicalBytes == 2 * 1024 * 1024)
    }
  }

  @Test func installerMatchesStayUncertainAndDuplicateNamesRequireEqualContents() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      for (name, contents) in [("Example-1.2.0-arm64.dmg", "installer"), ("report.pdf", "same"),
                               ("report (1).pdf", "same"), ("report (2).pdf", "diff")] {
        try helper.write(contents, "Downloads/" + name, home: home)
      }
      let app = ApplicationIdentity(name: "Example", bundleID: "com.example.app", path: "/Applications/Example.app")
      let roots = try DownloadsInventory.discover(home: home, applications: [app], volumes: ScanVolumes(home: home, projects: []), includeProtected: true)
      #expect(roots.first { $0.url.pathExtension == "dmg" }?.evidence?.finding == .installerMatch)
      #expect(roots.first { $0.url.lastPathComponent == "report (1).pdf" }?.evidence?.finding == .duplicateDownload)
      #expect(!roots.contains { $0.url.lastPathComponent == "report (2).pdf" && $0.evidence?.finding == .duplicateDownload })
      #expect(roots.allSatisfy { $0.evidence?.inspectionOnly == true })
      #expect(try String(contentsOf: home.appending(path: "Downloads/report (1).pdf"), encoding: .utf8) == "same")
    }
  }
  @Test func exclusionsSymlinksAndBudgetsNeverCreateDuplicateSuggestions() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      try helper.write("same", "Downloads/file.bin", home: home)
      try helper.write("same", "Downloads/file (1).bin", home: home)
      try FileManager.default.createSymbolicLink(at: home.appending(path: "Downloads/file (2).bin"), withDestinationURL: home.appending(path: "Downloads/file.bin"))
      let roots = try DownloadsInventory.discover(home: home, applications: [], volumes: ScanVolumes(home: home, projects: []), includeProtected: true, comparisonBudget: 0)
      #expect(!roots.contains { $0.evidence?.finding == .duplicateDownload })
      let excluded = try ScanExclusions.$current.withValue(.init(paths: [home.appending(path: "Downloads/file.bin").path])) {
        try DownloadsInventory.discover(home: home, applications: [], volumes: ScanVolumes(home: home, projects: []), includeProtected: true)
      }
      #expect(!excluded.contains { $0.evidence?.finding == .duplicateDownload })
    }
  }

  @Test func protectedLocationsMustBeEnabledBeforeDownloadsIsOpened() throws {
    // A nonexistent home proves this branch does not open or enumerate Downloads.
    let home = URL(fileURLWithPath: "/private/tmp/macpurge-no-download-access-" + UUID().uuidString)
    let roots = try DownloadsInventory.discover(home: home, applications: [],
      volumes: ScanVolumes(home: home, projects: []), includeProtected: false)
    #expect(roots.count == 1)
    guard case .status(let reason) = roots[0].source else {
      Issue.record("Downloads must stay unavailable while protected-location scanning is off")
      return
    }
    let item = ScanReport.makeItems(roots: roots,
      results: [roots[0].id: RootSize(state: .unavailable(reason))], homeDevice: nil)[0]
    #expect(InventoryExplanation(item: item).finding == reason)
  }
}
