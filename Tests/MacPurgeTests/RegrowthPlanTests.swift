import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct RegrowthPlanTests {
  private let hour: TimeInterval = 3600

  private func item(
    _ name: String, _ bytes: Int64, volume: Int32 = 7, inode: UInt64 = 20,
    status: String = "complete", safety: SafetyLevel = .safe
  ) -> ReportItem {
    .init(
      id: name, name: name, category: ScanGroup.packages.rawValue, path: "/cache/" + name,
      bytes: bytes, status: status, safety: safety.rawValue, reason: "", basis: "allocated",
      eligibleBytes: bytes, modified: nil, parts: [:], volume: volume, directoryInode: inode)
  }
  private func report(_ rows: [ReportItem], at time: Date) -> ScanReport {
    .init(id: UUID(), date: time, extended: false, free: nil, capacity: nil, items: rows)
  }
  private func move(_ row: ReportItem, at time: Date, bytes: Int64, url: URL? = nil) -> MovedFolder
  {
    var info = stat()
    info.st_dev = row.volume ?? 0
    info.st_ino = 10
    let identity = FileIdentity(info)
    return .init(
      receipt: .init(
        id: UUID(), original: url ?? URL(fileURLWithPath: row.path),
        parent: identity, identity: identity, bytes: bytes, date: time),
      itemID: row.id, name: row.name, workspace: row.workspace)
  }

  @Test func durableCandidatesMeetGoalBeforeFastCacheAndFallbackRemainsAvailable() async throws {
    let now = Date.now
    let fast = item("fast", 110)
    let a = item("a", 60)
    let b = item("b", 40)
    let rows = [
      fast, a, b, item("blocked", 250), item("hidden", 300),
      item("review", 400, safety: .review), item("partial", 500, status: "partial"),
    ]
    let snapshot = report(rows, at: now)
    let readings = try await MovedFolder.regrown(
      [move(fast, at: now - 72 * hour, bytes: 220)], in: snapshot)
    var states = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, MoveAvailability.ready) })
    states["blocked"] = .blocked("busy")
    func ids(_ target: Int64, _ history: [RegrownFolder]) -> [String] {
      snapshot.plan(
        target: target, excluding: ["hidden"], moveStates: states, regrowth: history, at: now
      ).map(\.id)
    }
    #expect(ids(100, readings) == ["a", "b"])
    #expect(ids(101, readings) == ["a", "b", "fast"])
    #expect(ids(999, readings) == ["a", "b", "fast"])
    #expect(ids(0, readings).isEmpty)
    #expect(ids(100, []) == ["fast"])
  }

  @Test func insufficientOrIncomparableHistoryKeepsSizeOrder() async throws {
    let now = Date.now
    let row = item("first", 100)
    let other = item("second", 80)
    let snapshot = report([row, other], at: now)
    let states = [row.id: MoveAvailability.ready, other.id: .ready]
    for receipt in [
      move(row, at: now, bytes: 100),
      move(row, at: now - 72 * hour - 1, bytes: 100),
      move(row, at: now - hour, bytes: 201),
      move(item("first", 100, volume: 8), at: now - hour, bytes: 100),
    ] {
      let evidence = try await MovedFolder.regrown([receipt], in: snapshot)
      #expect(
        snapshot.plan(target: 80, moveStates: states, regrowth: evidence, at: now).first?.id
          == row.id)
    }
    let receipt = move(row, at: now - hour, bytes: 100)
    let putBack = report(
      [item("first", 100, inode: receipt.receipt.identity.inode), other], at: now)
    #expect(try await MovedFolder.regrown([receipt], in: putBack).isEmpty)
    let ties = report([item("z", 80), item("a", 80)], at: now)
    #expect(ties.plan(target: 1, moveStates: ["a": .ready, "z": .ready]).first?.id == "a")
  }

  @Test func observationSurvivesRestartAndLateScansButCannotReviveUndoneOrReplacedMove()
    async throws
  {
    let tmp = URL(fileURLWithPath: "/private/tmp/MacPurge-Plan-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let archive = ScanArchive(file: tmp.appending(path: "history.sqlite"))
    let early = Date.now - 10 * 24 * hour
    let big = item("big", 100)
    let small = item("small", 80)
    let original = move(big, at: early - hour, bytes: 100)
    let snapshot = report([big, small], at: early)
    try archive.remember([original])
    let reading = try #require(try await MovedFolder.regrown([original], in: snapshot).first)
    #expect(reading.move.rapidReturnAt == early)
    try archive.remember([reading.move], updatingEvidence: true)
    let reopened = ScanArchive(file: archive.file)
    let saved = try #require(try reopened.movedFolders().first)
    #expect(saved.rapidReturnAt == early)
    let later = Date.now
    let fresh = report([big, small], at: later)
    let history = try await MovedFolder.regrown([saved], in: fresh)
    let states = [big.id: MoveAvailability.ready, small.id: .ready]
    #expect(
      fresh.plan(target: 80, moveStates: states, regrowth: history, at: later).first?.id == small.id
    )
    #expect(
      fresh.plan(
        target: 80, moveStates: states, regrowth: history,
        at: early + 31 * 24 * hour
      ).first?.id == big.id)
    try reopened.forgetMove(at: big.path)
    try reopened.remember([reading.move], updatingEvidence: true)
    #expect(try reopened.movedFolders().isEmpty)
    let newer = move(big, at: original.receipt.date, bytes: 200)
    try reopened.remember([newer])
    try reopened.remember([reading.move], updatingEvidence: true)
    let remaining = try #require(try reopened.movedFolders().first)
    #expect(remaining.receipt.id == newer.receipt.id && remaining.rapidReturnAt == nil)
  }

  @Test func smallSimulatorCacheDoesNotDemoteWholeDeviceButMaterialCombinedRegrowthDoes()
    async throws
  {
    let root = URL(fileURLWithPath: "/private/tmp/MacPurge-Plan-Device-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appending(path: "data/Library/Caches")
    let temp = root.appending(path: "data/tmp")
    for url in [cache, temp] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data(repeating: 42, count: 65536).write(to: url.appending(path: "bytes"))
    }
    let probe = try await StorageMeter.measure(
      .init(group: .simulators, title: "probe", url: cache))
    let single = probe.bytes
    #expect(single > 0)
    let dev = try #require(probe.measuredDevice)
    let row = ReportItem(
      id: "device/cache", name: "cache", category: ScanGroup.simulators.rawValue,
      path: root.path, bytes: 3 * single, status: "complete", safety: SafetyLevel.safe.rawValue,
      reason: "", basis: "allocated", eligibleBytes: 3 * single, modified: nil, parts: [:],
      volume: dev)
    let other = item("other", 2 * single)
    let now = Date.now
    let snapshot = report([row, other], at: now)
    let moves = [cache, temp].map { move(row, at: now - hour, bytes: single, url: $0) }
    let readings = try await MovedFolder.regrown(moves, in: snapshot)
    #expect(readings.count == 2)
    let device = try await StorageMeter.measure(
      .init(group: .simulators, title: "phone", url: root))
    try FileManager.default.removeItem(at: cache)
    try FileManager.default.removeItem(at: temp)
    let captured = try await MovedFolder.regrown(
      moves, in: snapshot, measuredCaches: device.cleanupReadings)
    #expect(captured.map(\.bytes) == readings.map(\.bytes))
    let states = [row.id: MoveAvailability.ready, other.id: .ready]
    #expect(
      snapshot.plan(target: single, moveStates: states, regrowth: Array(readings.prefix(1))).first?
        .id == row.id)
    #expect(
      snapshot.plan(target: single, moveStates: states, regrowth: readings).first?.id == other.id)
  }

  @Test func legacySnapshotsCanProveFastReturnOnlyForTheSameMeasuredFolder() async throws {
    let now = Date.now
    let big = item("big", 200)
    let small = item("small", 100)
    let moved = move(big, at: now - 7 * 24 * hour, bytes: 200)
    var current = report([big, small], at: now)
    current.scope = "quick"
    let early = moved.receipt.date + hour
    func archived(_ row: ReportItem, scope: String = "quick") -> ScanReport {
      var scan = report([row], at: early)
      scan.scope = scope
      return scan
    }
    let invalid = [
      archived(big, scope: "other-scope"),
      archived(item("big", 300, inode: moved.receipt.identity.inode)),
      archived(item("big", 300, volume: 99)), archived(item("big", 99)),
      archived(item("big", 300, status: "partial")),
    ]
    let states = [big.id: MoveAvailability.ready, small.id: .ready]
    let inconclusive = try await MovedFolder.regrown([moved], in: current, history: invalid)
    #expect(
      current.plan(target: 100, moveStates: states, regrowth: inconclusive, at: now).first?.id
        == big.id)
    let verified = try await MovedFolder.regrown(
      [moved], in: current,
      history: invalid + [archived(item("big", 100))])
    #expect(verified.first?.move.rapidReturnAt == early)
    #expect(
      current.plan(target: 100, moveStates: states, regrowth: verified, at: now).first?.id
        == small.id)
  }
}
