import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct VersionInventoryTests {
  @Test func numericOrderingDoesNotConfuseMinorVersionsOrPrereleases() {
    #expect(VersionInventory.Version("20.10.0")! > VersionInventory.Version("20.9.0")!)
    #expect(VersionInventory.Version("v20.10.0") == VersionInventory.Version("20.10.0"))
    #expect(VersionInventory.Version("20.1.0-beta") == nil)
    #expect(VersionInventory.Version("../../20") == nil)
  }
  @Test func defaultsAndReleaseFamiliesRemainProtectedAndMetadataIsRequired() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      for version in ["v20.9.0", "v20.10.0", "v22.1.0"] {
        try helper.write("runtime", ".nvm/versions/node/" + version + "/bin/node", home: home)
      }
      try helper.write("20.9.0", ".nvm/alias/default", home: home)
      let roots = try VersionInventory.discover(home: home, volumes: ScanVolumes(home: home, projects: []), brewPrefixes: [])
      #expect(roots.first { $0.url.lastPathComponent == "v20.9.0" }?.evidence?.finding == .currentVersion)
      #expect(roots.allSatisfy { $0.evidence?.inspectionOnly == true })
      try helper.write("22", ".nvm/alias/default", home: home)
      let changed = try VersionInventory.discover(home: home, volumes: ScanVolumes(home: home, projects: []), brewPrefixes: [])
      #expect(changed.first { $0.url.lastPathComponent == "v20.9.0" }?.evidence?.finding == .olderVersion)
      try helper.write("unknown-alias", ".nvm/alias/default", home: home)
      let unknown = try VersionInventory.discover(home: home, volumes: ScanVolumes(home: home, projects: []), brewPrefixes: [])
      #expect(!unknown.contains { $0.evidence?.finding == .olderVersion })
    }
  }
  @Test func brewUsesTheLinkedVersionAndNeverOffersDirectRemoval() async throws {
    let helper = DeveloperDataInventoryTests()
    try await helper.fixture { home in
      let prefix = home.appending(path: "brew")
      for version in ["1.2.0", "1.3.0"] { try helper.write("tool", "brew/Cellar/example/" + version + "/bin/tool", home: home) }
      try FileManager.default.createDirectory(at: prefix.appending(path: "opt"), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: prefix.appending(path: "opt/example"), withDestinationURL: prefix.appending(path: "Cellar/example/1.2.0"))
      let roots = try VersionInventory.discover(home: home, volumes: ScanVolumes(home: home, projects: []), brewPrefixes: [prefix])
      #expect(roots.first { $0.url.lastPathComponent == "1.2.0" }?.evidence?.finding == .currentVersion)
      #expect(roots.first { $0.url.lastPathComponent == "1.3.0" }?.evidence?.finding != .olderVersion)
      #expect(roots.allSatisfy { $0.evidence?.inspectionOnly == true })
    }
  }
}
