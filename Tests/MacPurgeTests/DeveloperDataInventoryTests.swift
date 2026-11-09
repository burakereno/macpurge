import Darwin
import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct DeveloperDataInventoryTests {
  func fixture(_ run: (URL) async throws -> Void) async throws {
    let home = URL(fileURLWithPath: "/private/tmp/macpurge-analysis-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try await run(home)
  }
  func write(_ value: String, _ path: String, home: URL) throws {
    let url = home.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
  }

  @Test func editorEvidenceDistinguishesMissingRemoteAndUnknownAndPreservesData() async throws {
    try await fixture { home in
      let base = "Library/Application Support/Code/User/workspaceStorage"
      try write("{}", "projects/present/package.json", home: home)
      try write("{\"folder\":\"\(home.appending(path: "projects/present").absoluteString)\"}", "\(base)/present/workspace.json", home: home)
      try write("{\"folder\":\"\(home.appending(path: "projects/missing").absoluteString)\"}", "\(base)/missing/workspace.json", home: home)
      try write("{\"folder\":\"vscode-remote://ssh-remote/remote\"}", "\(base)/remote/workspace.json", home: home)
      try write("broken", "\(base)/unknown/workspace.json", home: home)
      try write("[{\"relativeLocation\":\"installed\"}]", ".vscode/extensions/extensions.json", home: home)
      try write("extension", ".vscode/extensions/installed/file", home: home)
      try write("leftover", ".vscode/extensions/leftover/file", home: home)
      let before = try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted()
      let rows = try DeveloperDataInventory.discover(home: home, volumes: ScanVolumes(home: home, projects: []))
      for finding in [InventoryEvidence.Finding.projectPresent, .missingProject, .remoteProject, .unknownProject,
                      .registeredExtension, .unregisteredExtension] {
        #expect(rows.contains { $0.evidence?.finding == finding })
      }
      #expect(rows.allSatisfy { $0.evidence?.inspectionOnly == true })
      #expect(try FileManager.default.subpathsOfDirectory(atPath: home.path).sorted() == before)
      #expect(try String(contentsOf: home.appending(path: "\(base)/unknown/workspace.json"), encoding: .utf8) == "broken")
    }
  }

  @Test func exclusionsAndSymlinksNeverBecomeMissingProjectEvidence() async throws {
    try await fixture { home in
      let project = home.appending(path: "hidden")
      let ws = "Library/Application Support/Cursor/User/workspaceStorage/one"
      try write("{\"folder\":\"\(project.absoluteString)\"}", ws + "/workspace.json", home: home)
      try write("data", "outside/file", home: home)
      try FileManager.default.createSymbolicLink(at: home.appending(path: ".vscode"), withDestinationURL: home.appending(path: "outside"))
      let rows = try ScanExclusions.$current.withValue(.init(paths: [project.path])) {
        try DeveloperDataInventory.discover(home: home, volumes: ScanVolumes(home: home, projects: []))
      }
      #expect(!rows.contains { $0.evidence?.finding == .missingProject })
      #expect(!rows.contains { $0.url.path.contains("/.vscode/") })
    }
  }

  @Test func aiDataHasExplicitBoundariesAndNeverBecomesSelectable() async throws {
    try await fixture { home in
      for (path, value) in [
        (".codex/log/cli.log", "diagnostic"), (".codex/sessions/session.jsonl", "private conversation"),
        (".codex/config.toml", "settings"), (".codex/cache/item", "cache"),
        (".claude/file-history/checkpoint", "original edit"),
        (".claude/projects/moved/sessions-index.json", "{\"originalPath\":\"\(home.path)/old-project\"}"),
        (".claude/projects/moved/session.jsonl", "private conversation"),
      ] { try write(value, path, home: home) }
      let volumes = ScanVolumes(home: home, projects: [])
      let details = try DeveloperDataInventory.discover(home: home, volumes: volumes)
      for kind in [InventoryEvidence.Kind.logs, .history, .settings, .cache, .checkpoint] {
        #expect(details.contains { $0.evidence?.kind == kind })
      }
      #expect(details.contains { $0.evidence?.finding == .missingProject })
      let broad = ScanRoot(group: .models, title: "Codex", url: home.appending(path: ".codex"), profile: .personal)
      let roots = InventoryPartition.merging([broad], details: details).map(volumes.restrict)
      let results = try await StorageMeter.scan(roots, onStart: { _ in }, onFinish: { _,_,_ in })
      var sizes: [String: RootSize] = [:]
      for root in roots { sizes[root.id] = try await StorageMeter.measure(root) }
      let rows = ScanReport.makeItems(roots: roots, results: sizes, homeDevice: sizes[broad.id]?.measuredDevice)
      let typed = rows.filter { $0.evidence != nil }
      #expect(!typed.isEmpty && typed.allSatisfy { !$0.safePlanCandidate })
      let manual = await ManualReview.candidates(roots: roots, results: sizes, rows: rows, home: home, projects: [])
      #expect(manual.moves.isEmpty)
      let engine = CacheTrash(home: home, journal: home.appending(path: "test-journal"))
      let actions = try await engine.actions(for: typed, projects: [], reportID: UUID(), readings: [:], manual: [:], restrictions: [:])
      #expect(actions.values.allSatisfy { action in
        if case .measurement = action { return true }
        return false
      })
      let codex = try await StorageMeter.measure(broad)
      var codexSum: Int64 = 0
      for root in roots where root.url.path.hasPrefix(broad.url.path) { codexSum += sizes[root.id]?.bytes ?? 0 }
      #expect(codexSum == codex.bytes)
      #expect(results[.models]?.bytes != nil)
      #expect(try String(contentsOf: home.appending(path: ".codex/sessions/session.jsonl"), encoding: .utf8) == "private conversation")
    }
  }

  @Test func malformedRegistriesDoNotMarkInstalledExtensionsAsLeftovers() async throws {
    try await fixture { home in
      try write("broken", ".vscode/extensions/extensions.json", home: home)
      try write("data", ".vscode/extensions/example/file", home: home)
      let roots = try DeveloperDataInventory.discover(home: home, volumes: ScanVolumes(home: home, projects: []))
      #expect(roots.first?.evidence?.finding == .unknownRegistry)
      let cache = ScanRoot(group: .apps, title: "Code Cache", url: home.appending(path: "cache"), profile: .renderCache)
      var detail = cache
      detail.evidence = .init(owner: "Code", kind: .cache, rule: "agent.cache")
      let merged = InventoryPartition.merging([cache], details: [detail])
      #expect(merged[0].profile == .renderCache && merged[0].evidence?.inspectionOnly == false)
    }
  }
}
