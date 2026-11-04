import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct UnifiedSafetyTests {
  private struct Fixture {
    let home = URL(filePath: "/private/tmp/macpurge-safety-" + UUID().uuidString)

    func write(_ path: String) throws {
      let url = home.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 65, count: 8192).write(to: url)
    }

    func prepare() throws {
      try write(".gradle/caches/9.4.1/transforms/cache")
      try write(".gradle/caches/build-cache-1/entry")
      // Gradle commonly shares cached files with a project through hard links.
      try FileManager.default.linkItem(at: home.appending(path: ".gradle/caches/9.4.1/transforms/cache"),
        to: home.appending(path: "project-dependency.jar"))
      try write(".gradle/init.d/custom.gradle")
      try write("Projects/App/package.json")
      try write("Projects/App/.next/cache/cache")
      try write("Projects/App/.next/server/output")
      try write("Projects/App/node_modules/dependency/modified")
      try write("Projects/App/Package.swift")
      try write("Projects/App/.build/install-backup/Old.app/executable")
      try write("Projects/App/.build/DerivedData/Build/Intermediates.noindex/output")
      try write("Projects/App/.build/DerivedData/Build/Products/Old.app.dSYM/symbols")
      try FileManager.default.createDirectory(
        at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
    }
  }

  @Test @MainActor func recoveryTotalsAgreeAcrossProjectsActionsAndFreshPreviews() async throws {
    let f = Fixture()
    defer { try? FileManager.default.removeItem(at: f.home) }
    try f.prepare()
    let source = f.home.appending(path: "Projects/App/package.json")
    let server = f.home.appending(path: "Projects/App/.next/server")
    try FileManager.default.linkItem(at: source, to: server.appending(path: "shared-source"))
    try FileManager.default.linkItem(at: server.appending(path: "output"),
      to: server.appending(path: "same-output"))
    try FileManager.default.linkItem(at: source,
      to: f.home.appending(path: "Projects/App/node_modules/shared-source"))
    var info = stat()
    try #require(lstat(source.path, &info) == 0)
    let sharedBytes = Int64(info.st_blocks) * 512
    let suite = UUID().uuidString
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    let engine = CacheTrash(home: f.home, journal: f.home.appending(path: "Journal"),
      packageIdle: { _ in true })
    let scan = LiveScan(defaults: prefs, recordsHistory: false, home: f.home, cleanupEngine: engine,
      localInventory: { _, _, _, _ in [] }, toolInventory: { _, _ in [] })
    scan.addProjects([f.home.appending(path: "Projects")])
    await scan.finishCurrentScan()
    await scan.refreshMoveStates()
    let report = try #require(scan.report)
    let output = try #require(report.items.first { $0.path == server.path })
    let modules = try #require(report.items.first { $0.path.hasSuffix("/node_modules") })
    #expect(output.sharedLinkBytes == sharedBytes)
    #expect(scan.action(for: output).bytes == (output.bytes ?? 0) - sharedBytes)
    #expect(scan.action(for: modules).bytes == (modules.bytes ?? 0) - sharedBytes)

    let projectItems = scan.projectCards.flatMap(\.outputs).compactMap(\.item)
    let safe = scan.safeMoves(projectItems)
    let total = scan.cleanupBytes(safe)
    #expect(total == scan.projectCards.reduce(0) { $0 + $1.reproducibleBytes })
    #expect(scan.cleanupBytes(safe + safe) == total)
    let preview = await engine.prepare(items: safe, reportID: report.id,
      projects: scan.protectedProjects)
    #expect(preview.skipped.isEmpty && preview.reclaimableBytes == total)
    #expect(preview.targets.reduce(0) { $0 + $1.snapshot.bytes } > total)
    let target = try #require(preview.targets.first { $0.path.path == server.path })
    #expect(target.snapshot.sharedBytes == sharedBytes)
    #expect(target.snapshot.reclaimableBytes == scan.action(for: output).bytes)

    let review = await engine.prepare(items: [modules], reportID: report.id,
      projects: scan.protectedProjects, manual: scan.manualMoves)
    #expect(review.skipped.isEmpty && review.needsReview)
    #expect(review.reclaimableBytes == scan.action(for: modules).bytes)
    let live = try await engine.currentPlanInputs(report, projects: scan.protectedProjects, hidden: [])
    #expect(live.report.items.first { $0.id == output.id }?.eligibleBytes == target.snapshot.reclaimableBytes)
    #expect(live.report.items.first { $0.id == output.id }?.bytes == target.snapshot.bytes)

    scan.hide(output)
    let visibleTotal = scan.cleanupBytes(scan.safeMoves(projectItems))
    #expect(visibleTotal == total - target.snapshot.reclaimableBytes)
    #expect(visibleTotal == scan.projectCards.reduce(0) { $0 + $1.reproducibleBytes })
  }

  @Test @MainActor func badgesFiltersSuggestionsAndDirectCleanupUseTheSameSafety() async throws {
    let f = Fixture()
    defer { try? FileManager.default.removeItem(at: f.home) }
    try f.prepare()
    let suite = UUID().uuidString
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    let engine = CacheTrash(
      home: f.home, journal: f.home.appending(path: "Journal"),
      packageIdle: { _ in true })
    let scan = LiveScan(
      defaults: prefs, recordsHistory: false, home: f.home, cleanupEngine: engine,
      localInventory: { _, _, _, _ in [] }, toolInventory: { _, _ in [] })
    scan.addProjects([f.home.appending(path: "Projects")])
    await scan.finishCurrentScan()
    let measured = try #require(scan.report?.items.first { $0.path.hasSuffix("/.gradle/caches") })
    #expect(scan.filterRisk(for: measured) == .safe)
    #expect(scan.action(for: measured).safety(for: measured) == .safe)
    await scan.refreshMoveStates()
    let report = try #require(scan.report)
    let safe = report.items.filter { $0.safety == SafetyLevel.safe.rawValue }
    let gradle = try #require(safe.first { $0.path.hasSuffix("/.gradle/caches") })
    #expect(gradle.reason.contains("Gradle") && gradle.reason.contains("yeniden"))
    for suffix in ["/.gradle/caches", "/.next/cache", "/.next/server", "/Intermediates.noindex"] {
      let row = try #require(safe.first { $0.path.hasSuffix(suffix) })
      #expect(scan.action(for: row).risk == .safe)
      #expect(scan.filterRisk(for: row) == .safe)
      #expect(scan.action(for: row).safety(for: row) == .safe)
      #expect(row.safePlanCandidate)
    }
    for suffix in ["/node_modules", "/install-backup", "/Build/Products"] {
      let row = try #require(report.items.first { $0.path.hasSuffix(suffix) })
      #expect(row.safety == SafetyLevel.review.rawValue)
      #expect(scan.filterRisk(for: row) == .review)
    }
    let automatic = report.rankedCandidates(
      excluding: [], moveStates: scan.moveStates, regrowth: [])
    #expect(Set(automatic.map(\.id)) == Set(safe.map(\.id)))
    let current = try await engine.currentPlanInputs(
      report, projects: scan.protectedProjects, hidden: [])
    #expect(Set(current.report.items.map(\.id)) == Set(safe.map(\.id)))
    let safePlan = await engine.prepare(
      items: safe, reportID: report.id, projects: scan.protectedProjects)
    #expect(
      safePlan.skipped.isEmpty && safePlan.targets.count == safe.count && !safePlan.needsReview)

    // The same no-plan, direct operation used by the UI must also work for newly Safe caches.
    scan.cleanup.prepare([gradle], scan: scan)
    await scan.cleanup.finishCurrentOperation()
    let preview = try #require(scan.cleanup.preview)
    #expect(preview.targets.count == 1 && !preview.needsReview)
    scan.cleanup.confirmMove(preview.id, scan: scan)
    await scan.cleanup.finishCurrentOperation()
    let result = try #require(scan.cleanup.outcome)
    #expect(result.moved.count == 1 && result.notices.isEmpty)
    #expect(result.moved[0].expectedRecoveryBytes == preview.reclaimableBytes)
    #expect(result.moved[0].bytes > result.moved[0].expectedRecoveryBytes)
    let dependency = try Data(contentsOf: f.home.appending(path: "project-dependency.jar"))
    #expect(dependency == Data(repeating: 65, count: 8192))
    #expect(
      FileManager.default.fileExists(
        atPath: f.home.appending(path: ".gradle/init.d/custom.gradle").path))
    #expect(
      FileManager.default.fileExists(
        atPath: f.home.appending(path: "Projects/App/.build/install-backup/Old.app/executable").path
      ))
    scan.cleanup.restore(result.moved[0], scan: scan)
    await scan.cleanup.finishCurrentOperation()
    #expect(FileManager.default.fileExists(atPath: gradle.path))

    // A stale Safe report cannot authorize project output after its generator declaration disappears.
    let cache = try #require(safe.first { $0.path.hasSuffix("/.next/cache") })
    try FileManager.default.removeItem(at: f.home.appending(path: "Projects/App/package.json"))
    let stale = await engine.prepare(
      items: [cache], reportID: report.id, projects: scan.protectedProjects)
    #expect(stale.targets.isEmpty && !stale.skipped.isEmpty)
  }

  @Test func safeClassificationDoesNotDisappearDuringABuild() {
    let row = ReportItem(
      id: "gradle", name: "Gradle", category: ScanGroup.packages.rawValue,
      path: "/home/.gradle/caches", bytes: 100, status: "complete",
      safety: SafetyLevel.safe.rawValue,
      reason: StorageProfile.gradleCacheReason, basis: "allocated", eligibleBytes: 100,
      modified: nil, parts: [:], volume: nil)
    let blocked = CleanupAction.unavailable(.inUse("Build running"))
    #expect(blocked.safety(for: row) == .safe && blocked.availability != .ready)
    #expect(
      !PackageTool.gradle.isIdle(
        in: "java -cp wrapper.jar org.gradle.wrapper.GradleWrapperMain build"))
    #expect(!PackageTool.gradle.isIdle(in: "/project/gradlew assemble"))
    #expect(
      PackageTool.gradle.isIdle(in: "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.4"))
    for profile in [StorageProfile.gradleCache, .projectCache, .projectBuild, .projectGradleCache] {
      #expect(profile.assessment(for: .partial)?.level == .review)
    }
  }
}
