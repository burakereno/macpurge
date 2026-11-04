import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// One successful move at one physical path. Device-level cache totals can span many such paths.
struct MovedFolder: Codable, Sendable {
  let receipt: TrashReceipt
  let itemID: String
  let name: String
  let workspace: String?
  // The first qualifying observation for this receipt. Older archives have no evidence.
  var rapidReturnAt: Date? = nil

  static let rapidWindow: TimeInterval = 72 * 3600
  static let planningHorizon: TimeInterval = 30 * 24 * 3600

  static func half(_ bytes: Int64) -> Int64 { bytes / 2 + bytes % 2 }

  static func from(_ result: TrashOutcome, plan: TrashPlan) -> [Self] {
    let targets = Dictionary(uniqueKeysWithValues: plan.targets.map { ($0.path.path, $0) })
    return result.moved.compactMap { receipt in
      guard receipt.review == nil, let target = targets[receipt.original.path] else { return nil }
      return Self(
        receipt: receipt, itemID: target.itemID, name: target.name, workspace: target.workspace)
    }
  }

  private func wasRapid(bytes: Int64, at observed: Date) -> Bool {
    let elapsed = observed.timeIntervalSince(receipt.date)
    return elapsed > 0 && elapsed <= Self.rapidWindow && receipt.bytes > 0
      && bytes >= Self.half(receipt.bytes)
  }

  @concurrent static func regrown(
    _ folders: [Self], in report: ScanReport,
    history: [ScanReport] = [], measuredCaches: [String: DirectoryReading]? = nil
  ) async throws
    -> [RegrownFolder]
  {
    guard !folders.isEmpty else { return [] }
    let items = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0) })
    // Old archives already have exact folder sizes and inodes. A simulator aggregate
    // cannot prove that any particular nested cache was present in those scans.
    let missing = Dictionary(
      uniqueKeysWithValues: folders.filter {
        $0.rapidReturnAt == nil && items[$0.itemID]?.path == $0.receipt.original.path
          && report.date.timeIntervalSince($0.receipt.date) <= planningHorizon + rapidWindow
      }.map { ($0.itemID, $0) })
    var earlier: [String: Date] = [:]
    if !missing.isEmpty, let scope = report.scope {
      for scan in history
      where scan.scope == scope && scan.extended == report.extended && scan.date < report.date {
        try Task.checkCancellation()
        for row in scan.items {
          guard let folder = missing[row.id], row.path == folder.receipt.original.path,
            row.complete, row.basis == "allocated", row.workspace == folder.workspace,
            row.volume == folder.receipt.identity.device, let inode = row.directoryInode,
            inode != folder.receipt.identity.inode, let bytes = row.bytes
          else { continue }
          let date = row.measuredAt ?? scan.date
          if folder.wasRapid(bytes: bytes, at: date), date <= report.date {
            earlier[row.id] = min(earlier[row.id] ?? date, date)
          }
        }
      }
    }
    var readings: [RegrownFolder] = []
    for folder in folders {
      try Task.checkCancellation()
      let receipt = folder.receipt
      guard report.date > receipt.date, let item = items[folder.itemID], item.complete,
        item.basis == "allocated", item.workspace == folder.workspace,
        item.volume == receipt.identity.device
      else { continue }
      let bytes: Int64?
      let inode: UInt64?
      let observedAt: Date
      if item.path == receipt.original.path {
        bytes = item.bytes
        inode = item.directoryInode
        observedAt = item.measuredAt ?? report.date
      } else {
        // A simulator's report row is the entire device. Only measure the specific cache that moved.
        guard item.category == ScanGroup.simulators.rawValue,
          item.safety == SafetyLevel.safe.rawValue,
          receipt.original.path.hasPrefix(item.path + "/")
        else { continue }
        let components = receipt.original.path.dropFirst(item.path.count + 1).split(separator: "/")
        var scope = SimulatorDirectory.device
        for component in components {
          guard scope != .cache else {
            scope = .other
            break
          }
          scope = scope.descending(into: String(component))
        }
        guard scope == .cache else { continue }
        if let measuredCaches, let cache = measuredCaches[receipt.original.path], cache.verified,
          cache.device == item.volume
        {
          bytes = cache.bytes
          inode = cache.inode
          observedAt = item.measuredAt ?? report.date
        } else if measuredCaches != nil && measuredCaches?[receipt.original.path] == nil {
          continue  // A complete live device measurement did not find this cache.
        } else {
          let size = try await StorageMeter.measure(
            .init(group: .simulators, title: item.name, url: receipt.original))
          guard size.state == .complete, size.measuredDevice == item.volume else { continue }
          bytes = size.bytes
          inode = size.measuredInode
          observedAt = .now  // Never backdate a fresh nested measurement to an archived scan.
        }
      }
      // A Finder Put Back also returns the original directory identity. It is not regeneration.
      guard let bytes, bytes > 0, let inode, inode != receipt.identity.inode else { continue }
      var verified = folder
      if verified.rapidReturnAt == nil {
        verified.rapidReturnAt =
          earlier[item.id] ?? (folder.wasRapid(bytes: bytes, at: observedAt) ? observedAt : nil)
      }
      readings.append(.init(move: verified, bytes: bytes, measuredAt: observedAt))
    }
    return readings.sorted {
      $0.bytes == $1.bytes
        ? $0.move.receipt.original.path < $1.move.receipt.original.path : $0.bytes > $1.bytes
    }
  }
}

struct RegrownFolder: Identifiable, Sendable {
  let move: MovedFolder
  let bytes: Int64
  let measuredAt: Date
  var id: UUID { move.receipt.id }

  /// A small tmp directory must not demote all the other caches in a simulator's plan row.
  static func deferredIDs(_ readings: [Self], candidates: [ReportItem], at now: Date) -> Set<String>
  {
    guard !readings.isEmpty else { return [] }
    let items = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    var bytes: [String: Int64] = [:]
    for reading in readings {
      let move = reading.move
      let receipt = move.receipt
      guard let item = items[move.itemID], let proof = move.rapidReturnAt,
        proof > receipt.date, proof.timeIntervalSince(receipt.date) <= MovedFolder.rapidWindow,
        proof <= reading.measuredAt, reading.measuredAt <= now,
        now.timeIntervalSince(proof) <= MovedFolder.planningHorizon,
        reading.bytes > 0, item.volume == receipt.identity.device, item.workspace == move.workspace
      else { continue }
      if item.path == receipt.original.path {
        guard let inode = item.directoryInode, inode != receipt.identity.inode else { continue }
      } else {
        guard item.category == ScanGroup.simulators.rawValue,
          receipt.original.path.hasPrefix(item.path + "/")
        else { continue }
      }
      // Cap the tally at the eligible size (including when several cache paths share a row).
      let prior = bytes[item.id, default: 0]
      bytes[item.id] = prior + min(reading.bytes, item.eligibleBytes - prior)
    }
    return Set(
      candidates.compactMap {
        bytes[$0.id, default: 0] >= MovedFolder.half($0.eligibleBytes) ? $0.id : nil
      })
  }
}
