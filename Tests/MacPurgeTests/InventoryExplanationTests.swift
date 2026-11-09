import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct InventoryExplanationTests {
  private func item(_ profile: StorageProfile) -> ReportItem {
    let root = ScanRoot(group: .xcode, title: "Build", url: URL(fileURLWithPath: "/not-read/Build"), profile: profile)
    return ScanReport.makeItems(roots: [root], results: [root.id: RootSize(bytes: 4096)], homeDevice: nil)[0]
  }

  @Test func buildExplanationUsesEvidenceWithoutAuthorizingCleanup() {
    let row = item(.xcodeIntermediate)
    let explanation = InventoryExplanation(item: row)
    #expect(explanation.impact.contains("build"))
    #expect(!explanation.finding.isEmpty && !explanation.purpose.isEmpty)
    #expect(!row.safePlanCandidate)
  }

  @Test func personalDataDoesNotBecomeDisposableFromItsAge() {
    let row = item(.personal)
    let explanation = InventoryExplanation(item: row)
    #expect(explanation.impact.contains("lost"))
    #expect(explanation.uncertainty != nil)
  }

  @Test func oldReportsDecodeAndNewEvidenceRoundTrips() throws {
    let row = item(.personal)
    let data = try JSONEncoder().encode(row)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "profile")
    json.removeValue(forKey: "evidence")
    let old = try JSONDecoder().decode(ReportItem.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.evidence == nil && old.profile == nil)
    #expect(!InventoryExplanation(item: old).purpose.isEmpty)
    #expect(try JSONDecoder().decode(ReportItem.self, from: data) == row)
  }

  @Test func savedProjectEvidenceIsRedactedFromDefaultExports() throws {
    var row = item(.personal)
    row.evidence = .init(owner: "Cursor", kind: .workspace, finding: .missingProject,
                         rule: "editor.workspace", projectPath: "/private/project-location")
    let report = ScanReport(id: UUID(), date: .now, extended: true, free: nil, capacity: nil, items: [row])
    let exported = String(decoding: try report.export(), as: UTF8.self)
    #expect(!exported.contains("project-location") && !exported.contains("not-read"))
    let saved = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(report))
    #expect(saved.items[0].evidence == row.evidence)
  }
}
