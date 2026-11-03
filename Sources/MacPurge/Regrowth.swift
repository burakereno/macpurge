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

  static func from(_ result: TrashOutcome, plan: TrashPlan) -> [Self] {
    let targets = Dictionary(uniqueKeysWithValues: plan.targets.map { ($0.path.path, $0) })
    return result.moved.compactMap { receipt in
      guard let target = targets[receipt.original.path] else { return nil }
      return Self(
        receipt: receipt, itemID: target.itemID, name: target.name, workspace: target.workspace)
    }
  }

  @concurrent static func regrown(_ folders: [Self], in report: ScanReport) async throws
    -> [RegrownFolder]
  {
    let items = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0) })
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
      if item.path == receipt.original.path {
        bytes = item.bytes
        inode = item.directoryInode
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
        let size = try await StorageMeter.measure(
          .init(group: .simulators, title: item.name, url: receipt.original))
        guard size.state == .complete, size.measuredDevice == item.volume else { continue }
        bytes = size.bytes
        inode = size.measuredInode
      }
      // A Finder Put Back also returns the original directory identity. It is not regeneration.
      guard let bytes, bytes > 0, let inode, inode != receipt.identity.inode else { continue }
      readings.append(.init(move: folder, bytes: bytes, measuredAt: report.date))
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
}
