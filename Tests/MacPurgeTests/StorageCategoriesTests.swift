import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct StorageCategoriesTests {
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
}
