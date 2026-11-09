import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct ApplicationInventoryTests {
  @Test func associatesApplicationsAndDeduplicatesSharedDataWithoutChangingFiles() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      let folder = home.appending(path: "Applications")
      try helper.write("bundle", "Applications/Example.app/Contents/MacOS/Example", home: home)
      let info: [String: String] = ["CFBundleIdentifier": "com.example.editor", "CFBundleName": "Example"]
      let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      try plist.write(to: home.appending(path: "Applications/Example.app/Contents/Info.plist"))
      try helper.write(String(repeating: "x", count: 8192), "Library/Caches/com.example.editor/cache", home: home)
      let data = home.appending(path: "Library/Application Support/com.example.editor")
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try FileManager.default.linkItem(at: home.appending(path: "Library/Caches/com.example.editor/cache"), to: data.appending(path: "linked"))
      try helper.write("old data", "Library/Containers/com.uninstalled.product/Data/file", home: home)
      let discovery = try ApplicationInventory.discover(home: home, includeProtected: true,
        volumes: ScanVolumes(home: home, projects: []), applicationFolders: [folder])
      let roots = InventoryPartition.merging([], details: discovery.roots).map { discovery.attributing($0, home: home) }
      var sizes: [String: RootSize] = [:]
      for root in roots { sizes[root.id] = try await StorageMeter.measure(root) }
      let apps = try ApplicationInventory.footprints(roots: roots, results: sizes)
      let app = try #require(apps.first)
      #expect(app.name == "Example" && app.complete)
      #expect(app.locations.count == 3)
      var union = GroupSize()
      for root in roots where root.application != nil { try union.include(try #require(sizes[root.id]), for: root) }
      #expect(app.measuredBytes == union.bytes)
      #expect(app.measuredBytes < app.locations.compactMap(\.bytes).reduce(0, +))
      #expect(roots.contains { $0.evidence?.finding == .unmatchedApplication })
      #expect(try String(contentsOf: data.appending(path: "linked"), encoding: .utf8).count == 8192)
      let rows = ScanReport.makeItems(roots: roots, results: sizes, homeDevice: sizes.values.first?.measuredDevice)
      let manual = await ManualReview.candidates(roots: roots, results: sizes, rows: rows, home: home, projects: [])
      #expect(manual.moves.isEmpty)
      #expect(try JSONDecoder().decode([ApplicationFootprint].self, from: JSONEncoder().encode(apps)) == apps)
      var partial = sizes
      partial[roots.first { $0.application != nil }!.id]?.state = .partial
      #expect(try ApplicationInventory.footprints(roots: roots, results: partial).first?.complete == false)
      let builder = ScanReportBuilder(id: UUID(), scope: "fixture", extended: true, disk: nil, device: nil)
      await builder.append(roots, results: sizes)
      let report = try await builder.snapshot(roots: roots, results: sizes, sizes: [:], pending: [],
        simulatorListIncomplete: false, last: nil, final: true)
      #expect(report.applications == apps)
      #expect(report.items.filter { $0.application?.name == "Example" }.count == 3)
    }
  }

  @Test func excludedAndLinkedBundlesAreNotIndexedAndAmbiguousOwnersStayUnknown() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      try helper.write("{}", "Applications/Linked.app/Contents/Info.plist", home: home)
      try FileManager.default.createSymbolicLink(at: home.appending(path: "Applications/Alias.app"), withDestinationURL: home.appending(path: "Applications/Linked.app"))
      let discovery = try ScanExclusions.$current.withValue(.init(paths: [home.appending(path: "Applications/Linked.app").path])) {
        try ApplicationInventory.discover(home: home, includeProtected: false,
          volumes: ScanVolumes(home: home, projects: []), applicationFolders: [home.appending(path: "Applications")])
      }
      #expect(discovery.roots.isEmpty)
    }
  }

  @Test func duplicateBundlesAndVendorFoldersDoNotAcquireAmbiguousData() {
    let first = ApplicationIdentity(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", path: "/Applications/Cursor.app")
    let second = ApplicationIdentity(name: "Cursor Beta", bundleID: first.bundleID, path: "/Applications/Cursor Beta.app")
    let index = ApplicationDiscovery(apps: [first, second], roots: [])
    let home = URL(fileURLWithPath: "/fixture")
    #expect(index.owner(of: home.appending(path: "Library/Application Support/Cursor"), home: home) == nil)
    #expect(index.owner(of: home.appending(path: "Library/Application Support/com.todesktop"), home: home) == nil)
  }
}
