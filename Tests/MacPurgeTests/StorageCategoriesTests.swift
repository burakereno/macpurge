import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct StorageCategoriesTests {
  @MainActor @Test func overviewKeepsFiveLargestPerCategoryAndStorageKeepsTheFullInventory()
    async throws
  {
    let home = URL(filePath: "/private/tmp/macpurge-overview-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let prefs = try #require(UserDefaults(suiteName: UUID().uuidString))
    let scan = LiveScan(
      defaults: prefs, recordsHistory: false, home: home,
      localInventory: { home, _, _, _ in
        var rows = (1...306).map { index in
          ScanRoot(group: .apps, title: "app-\(index)", url: home.appending(path: "app-\(index)"),
                   source: .allocation(Int64(index)))
        }
        rows += (1...8).map { index in
          ScanRoot(group: .models, title: "model-\(index)", url: home.appending(path: "model-\(index)"),
                   source: .allocation(Int64(index)))
        }
        rows += [
          ScanRoot(group: .apps, title: "empty", url: home.appending(path: "empty"), source: .allocation(0)),
          ScanRoot(group: .apps, title: "absent", url: home.appending(path: "absent")),
          ScanRoot(group: .apps, title: "unreadable", url: home.appending(path: "unreadable"), source: .status("Erişim izni yok")),
        ]
        return rows
      }, toolInventory: { _, _ in [] })
    scan.startDetailed()
    await scan.finishCurrentScan()
    let apps = try #require(scan.overviewCategories[.apps])
    #expect(apps.largest.map(\.root.title) == ["app-306", "app-305", "app-304", "app-303", "app-302"])
    #expect(apps.counts[.review] == 307 && apps.hasIncompleteItems && apps.pendingCount == 0)
    let total = try #require(scan.groupBytes[.apps])
    #expect(total == Int64(306 * 307 / 2))
    #expect(scan.overviewCategories[.models]?.largest.map(\.bytes) == [8, 7, 6, 5, 4])
    let report = try #require(scan.storageReport)
    let stored = report.items.filter { $0.category == ScanGroup.apps.rawValue }
    #expect(stored.count == 308 && stored.contains { $0.name == "empty" })
    #expect(stored.filter { !$0.complete }.map(\.name) == ["unreadable"])

    scan.startQuick()
    await scan.finishCurrentScan()
    #expect(scan.overviewCategories[.apps] == nil && scan.overviewCategories[.models] == nil)
  }

  @Test func partialMeasurementsCompeteByKnownBytesAndTiesHaveStableOrder() {
    var preview = OverviewCategory()
    for title in ["Z", "Y", "X", "W", "V", "U", "Partial", "Partial zero"] {
      let root = ScanRoot(group: .projects, title: title, url: URL(filePath: "/test/" + title))
      preview.register(root)
      let bytes: Int64 = title == "Partial" ? 20 : (title == "Partial zero" ? 0 : 10)
      preview.record(RootSize(bytes: bytes, state: title.hasPrefix("Partial") ? .partial : .complete), for: root)
    }
    #expect(preview.largest.map(\.root.title) == ["Partial", "U", "V", "W", "X"])
    #expect(preview.hasIncompleteItems && preview.counts[.review] == 8)
  }

  @Test func specificModelAndProtectedFoldersAreNeverCountedAsAppData() async throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let model = root.appending(path: "Browser/Profile/Model")
    let skipped = root.appending(path: "MobileSync")
    for path in [
      model, skipped, root.appending(path: "Browser/Profile/History"),
      root.appending(path: "Browser/ProfileBackup"), root.appending(path: "CloudDocs"),
      root.appending(path: "MailClient"),
    ] {
      try fm.createDirectory(at: path, withIntermediateDirectories: true)
      try Data(repeating: 5, count: 8192).write(to: path.appending(path: "data"))
    }
    try fm.createSymbolicLink(at: root.appending(path: "Alias"), withDestinationURL: model)
    let roots = try CategoryLocations.unclaimed(
      in: root, group: .apps, profile: .personal,
      excluding: [model, skipped], allow: { $0 != "CloudDocs" })
    #expect(
      Set(roots.map(\.title)) == ["Browser/Profile/History", "Browser/ProfileBackup", "MailClient"])
    #expect(try Data(contentsOf: model.appending(path: "data")).count == 8192)
  }

  @Test func selectedFolderDiscoveryRespectsThresholdOwnershipAndLinks() throws {
    let fm = FileManager.default
    let project = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? fm.removeItem(at: project) }
    for name in ["big", "small", "reserved"] {
      try fm.createDirectory(at: project.appending(path: name), withIntermediateDirectories: true)
    }
    try fm.createSymbolicLink(at: project.appending(path: "alias"), withDestinationURL: project)
    let limit: Int64 = 500 * 1024 * 1024
    let size = RootSize(largest: [
      "big": limit, "small": limit - 1, "reserved": limit, "alias": limit,
    ])
    let rows = try CategoryLocations.largeFolders(
      in: project, excluding: [project.appending(path: "reserved")], measurement: size)
    #expect(rows.map(\.title) == ["big"])
    #expect(rows.first?.profile.assessment(for: .complete)?.level == .review)
  }

  @Test func deltasRequireAnEarlierCompleteMeasurementWithTheSameScope() throws {
    let project = URL(fileURLWithPath: "/work/A")
    let scope = ScanReport.scopeKey(extended: true, protected: false, projects: [project])
    let day = Date.now
    func report(_ date: Date, _ scope: String?, _ groups: [String: Int64]) -> ScanReport {
      .init(
        id: UUID(), date: date, extended: true, free: nil, capacity: nil,
        items: [], groups: groups, scope: scope)
    }
    let before = report(day, scope, ["Xcode": 50, "packages": 20, "partial": 32])
    let after = report(day.addingTimeInterval(3), scope, ["Xcode": 70, "packages": 10])
    let old = report(day, nil, ["Xcode": 500])
    let protected = report(
      day.addingTimeInterval(1),
      ScanReport.scopeKey(extended: true, protected: true, projects: [project]), ["Xcode": 9])
    let noProjects = report(
      day.addingTimeInterval(2),
      ScanReport.scopeKey(extended: true, protected: false, projects: []), ["Xcode": 4])
    let previous = after.previous(in: [after, noProjects, protected, old, before])
    #expect(previous?.id == before.id)
    #expect(after.makeDeltas(since: previous) == ["Xcode": 20, "packages": -10])
    #expect(after.makeDeltas(since: protected).isEmpty)
    #expect(after.previous(in: [old]) == nil)
  }

  @Test func runtimeDetailsDistinguishUnknownUsagePartialAndDuplicateBuilds() throws {
    let base = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Images")
    let data = Data(
      #"{"a":{"runtimeIdentifier":"iOS","build":"A","lastUsedAt":"2026-11-03T09:38:49Z"},"b":{"runtimeIdentifier":"iOS","build":"B","lastUsedAt":"2026-11-03T09:38:49.123Z"},"c":{"runtimeIdentifier":"tvOS","build":"C"}}"#
        .utf8)
    let phone = SimulatorDevice(id: UUID(), name: "Phone", runtime: "iOS")
    let root = ScanRoot(group: .simulators, title: phone.name, url: base, device: phone)
    var inventory = SimulatorInventory()
    inventory.roots = [root]
    let rows = try ExtendedInventory.runtimeRows(
      data: data, devices: inventory, sdkBuilds: [], base: base)
    #expect(rows[0].runtimeUsage?.lastUsed != nil && rows[1].runtimeUsage?.lastUsed != nil)
    #expect(
      rows[0].runtimeUsage?.devices == [phone] && rows[0].runtimeUsage?.multipleImages == true)
    #expect(rows[2].runtimeUsage?.lastUsed == nil && rows[2].runtimeUsage?.devices.isEmpty == true)
    #expect(
      rows[2].runtimeUsage?.deviceListComplete == true && rows[2].title.contains("eşleşmesi yok"))
    inventory.note = "Eksik"
    let partial = try ExtendedInventory.runtimeRows(
      data: data, devices: inventory, sdkBuilds: [], base: base)
    #expect(
      partial[2].runtimeUsage?.deviceListComplete == false
        && !partial[2].title.contains("eşleşmesi yok"))
    let report = ScanReport.make(
      roots: rows, results: [rows[0].id: RootSize(bytes: 100)], disk: nil, extended: true,
      homeDevice: nil)
    let saved = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(report))
    #expect(saved.items.first?.runtimeUsage == rows[0].runtimeUsage)
  }

  @Test func groupSummaryUsesDeduplicatedBytesAndDistinguishesMissingMeasurements() throws {
    var report = ScanReport(
      id: UUID(), date: .now, extended: true, free: nil, capacity: nil, items: [])
    report.groups = [ScanGroup.models.rawValue: 82, ScanGroup.temp.rawValue: 0]
    report.measuredGroupBytes = [ScanGroup.models.rawValue: 82, ScanGroup.apps.rawValue: 31]
    #expect(CategorySize.read(.models, in: report) == .bytes(82, lowerBound: false))
    #expect(CategorySize.read(.temp, in: report) == .bytes(0, lowerBound: false))
    #expect(CategorySize.read(.apps, in: report) == .bytes(31, lowerBound: true))
    #expect(CategorySize.read(.android, in: report) == .empty)
    let quick = ScanReport(
      id: UUID(), date: .now, extended: false, free: nil, capacity: nil, items: [])
    #expect(CategorySize.read(.android, in: quick) == .outsideScope)
    #expect(CategorySize.read(.models, in: nil) == .waiting)
  }

  @Test func storageSectionsCoverTheInventoryAndKeepPartialTotals() {
    #expect(StorageSection.allCases.count == 7)
    #expect(StorageSection.containing(ScanGroup.appCaches.rawValue) == .appCaches)
    for group in ScanGroup.allCases {
      let sections = StorageSection.allCases.filter { section in
        section.subgroups.contains { $0.groups.contains(group) }
      }
      #expect(sections.count == 1)
      #expect(sections.first == StorageSection.containing(group.rawValue))
    }
    let report = ScanReport(id: UUID(), date: .now, extended: false, free: nil, capacity: nil,
      items: [], groups: [ScanGroup.xcode.rawValue: 20, ScanGroup.packages.rawValue: 15])
    #expect(StorageSection.development.size(in: report) == .bytes(35, lowerBound: true))
    #expect(StorageSection.virtualization.size(in: report) == .outsideScope)
  }

  @Test func appCacheDiscoveryClaimsOnlyRecognizedPhysicalBoundaries() throws {
    let fm = FileManager.default
    let home = URL(filePath: "/private/tmp/macpurge-app-caches-" + UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    let base = home.appending(path: "Library/Application Support/Framer")
    let cache = base.appending(path: "Partitions/framer/Cache")
    let outer = home.appending(path: "Library/Caches/com.framer.electron")
    let nested = base.appending(path: "Partitions/framer/Code Cache")
    for path in [cache.appending(path: "Cache_Data"), outer, nested, base.appending(path: "Cache"),
      base.appending(path: "Service Worker/CacheStorage"), home.appending(path: "Library/Caches/Mystery")]
    {
      try fm.createDirectory(at: path, withIntermediateDirectories: true)
    }
    try Data("{}".utf8).write(to: base.appending(path: "Partitions/framer/Network Persistent State"))
    try fm.createSymbolicLink(at: base.appending(path: "Partitions/framer/GPUCache"), withDestinationURL: outer)
    let claimed = ScanRoot(group: .tools, title: "Reserved", url: nested)
    let roots = try AppCacheRule.discover(home: home, includeProtected: false,
      volumes: ScanVolumes(home: home, projects: []), claimed: [claimed], apps: [])
    #expect(Set(roots.map(\.url.path)) == [outer.path, cache.path])
    #expect(roots.allSatisfy { $0.profile == .appCache && $0.evidence?.rule == "app-cache.com.framer.electron" })
    let appData = ScanRoot(group: .apps, title: "Framer", url: base)
    let partition = InventoryPartition.merging([appData], details: roots)
    #expect(partition.first { $0.group == .apps }?.excludedDirectories == ["Partitions/framer/Cache"])
  }

  @Test func protectedCacheMeasurementsPreserveLatestRecordsAndStayReadOnly() async throws {
    let fm = FileManager.default
    let home = URL(filePath: "/private/tmp/macpurge-protected-caches-" + UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    let base = home.appending(path: ProtectedCacheInventory.coreDevicePath + "/com.example.app")
    let device = UUID().uuidString
    let old = base.appending(path: String(repeating: "a", count: 64) + "/" + device)
    let latest = base.appending(path: String(repeating: "b", count: 64) + "/" + device)
    let onlyForAnotherDevice = base.appending(path: String(repeating: "c", count: 64) + "/" + UUID().uuidString)
    let telegram = home.appending(path: ProtectedCacheInventory.telegramPath)
    let media = telegram.appending(path: "stable/account-1/postbox/media")
    let linked = telegram.appending(path: "account-2/postbox")
    for url in [old, latest, onlyForAnotherDevice, media, linked] {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 8192).write(to: url.appending(path: "payload"))
    }
    try fm.createSymbolicLink(at: linked.appending(path: "media"), withDestinationURL: media)
    let day: TimeInterval = 86_400
    let now = Date.now
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(day * 3)],
      ofItemAtPath: latest.path)
    let volumes = ScanVolumes(home: home, projects: [])
    let core = try ProtectedCacheInventory.coreDevice(home: home, volumes: volumes,
      now: now.addingTimeInterval(day * 20))
    #expect(core.map(\.url.path) == [old.path])
    let mediaRows = try ProtectedCacheInventory.telegram(home: home, volumes: volumes, apps: [])
    #expect(mediaRows.map(\.url.path) == [media.path])
    #expect(core.first?.group == .tools && mediaRows.first?.group == .appCaches)
    let partition = InventoryPartition.merging([
      ScanRoot(group: .apps, title: "Telegram", url: telegram),
    ], details: mediaRows)
    #expect(partition.first { $0.group == .apps }?.excludedDirectories == ["stable/account-1/postbox/media"])
    let roots = core + mediaRows
    let sizes = try await StorageMeter.scan(roots.map(volumes.restrict), onStart: { _ in }, onFinish: { _, _, _ in })
    #expect(sizes[.tools]?.bytes == 8192 && sizes[.appCaches]?.bytes == 8192)
    let reportItems = roots.map { root in
      ReportItem(id: root.id, name: root.title, category: root.group.rawValue, path: root.url.path,
        bytes: 8192, status: "complete", safety: SafetyLevel.review.rawValue, reason: "",
        basis: "allocated", eligibleBytes: 0, modified: nil, parts: [:],
        volume: volumes.device(for: home), profile: root.profile, evidence: root.evidence)
    }
    let engine = CacheTrash(home: home, journal: home.appending(path: "receipts"))
    let actions = try await engine.actions(for: reportItems, projects: [], reportID: UUID(),
      readings: [:], manual: [:], restrictions: [:])
    #expect(reportItems.allSatisfy { actions[$0.id]?.bytes == 0 && actions[$0.id]?.availability != .ready })
  }

  @Test func rescanKeepsEachCategoryUntilItsNewMeasurementIsReady() {
    let scope = ScanReport.scopeKey(extended: true, protected: false, projects: [])
    func reading(_ group: ScanGroup, _ name: String, _ bytes: Int64) -> (ScanRoot, RootSize) {
      (
        .init(group: group, title: name, url: URL(filePath: "/test/" + name)),
        RootSize(bytes: bytes)
      )
    }
    func snapshot(_ entries: [(ScanRoot, RootSize)], at date: Date) -> ScanReport {
      let rows = ScanReport.make(
        roots: entries.map(\.0),
        results: Dictionary(uniqueKeysWithValues: entries.map { ($0.0.id, $0.1) }),
        disk: nil, extended: true, homeDevice: nil)
      let totals = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.0.group.rawValue, $0.1.bytes) })
      return ScanReport(
        id: rows.id, date: date, extended: true, free: nil, capacity: nil,
        items: rows.items, groups: totals,
        groupSafety: totals.mapValues { .init(safe: 0, review: $0) },
        measuredGroupBytes: totals, scope: scope)
    }
    let now = Date.now
    let old = snapshot(
      [
        reading(.xcode, "build", 8), reading(.packages, "old-cache", 30),
        reading(.temp, "gone", 12),
      ], at: now.addingTimeInterval(-3600))
    let new = snapshot([reading(.xcode, "build", 20), reading(.packages, "new-cache", 3)], at: now)

    let halfway = new.retainingPending([.packages, .temp], from: old)
    #expect(halfway.date == old.date)
    #expect(
      Dictionary(uniqueKeysWithValues: halfway.items.map { ($0.name, $0.bytes) }) == [
        "build": 20, "old-cache": 30, "gone": 12,
      ])
    #expect(CategorySize.read(.xcode, in: halfway) == .bytes(20, lowerBound: false))
    #expect(CategorySize.read(.packages, in: halfway) == .bytes(30, lowerBound: false))
    #expect(halfway.groupSafety?[ScanGroup.packages.rawValue]?.review == 30)
    #expect(halfway.measuredGroupBytes?[ScanGroup.packages.rawValue] == 30)

    // Once temp was measured as empty, neither its old item nor its bar should survive.
    let next = new.retainingPending([.packages], from: old)
    #expect(!next.items.contains { $0.name == "gone" })
    #expect(CategorySize.read(.temp, in: next) == .empty)
    #expect(next.groupSafety?[ScanGroup.temp.rawValue] == nil)
    #expect(new.retainingPending([], from: old).items == new.items)

    var otherScope = old
    otherScope.scope = ScanReport.scopeKey(extended: true, protected: true, projects: [])
    #expect(new.retainingPending([.packages], from: otherScope).items == new.items)
    #expect(new.retainingPending([.packages], from: nil).date == now)
  }
}
