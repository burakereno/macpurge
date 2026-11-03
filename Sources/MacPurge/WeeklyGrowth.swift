import Foundation

/// Each day contributes its last completed scan of the same scope.
struct WeeklyGrowth: Sendable {
  struct Sample: Identifiable, Sendable {
    let date: Date
    let bytes: Int64
    var id: Date { date }
  }
  struct Folder: Identifiable, Sendable {
    let item: ReportItem
    let bytes: Int64
    let firstSeen: Bool
    var id: String { item.id }
  }
  struct Category: Identifiable, Sendable {
    let name: String
    let change: Int64
    let samples: [Sample]
    let folders: [Folder]
    var id: String { name }
  }

  let start: Date
  let end: Date
  let measuredDays: Int
  let comparableCategories: Int
  let categories: [Category]

  init(current: ScanReport, earlierDays: [ScanReport]) {
    let earlier = earlierDays.filter {
      current.scope != nil && $0.scope == current.scope && $0.extended == current.extended
        && $0.date < current.date
    }.sorted { $0.date < $1.date }
    let baseline = earlier.first ?? current
    start = baseline.date
    end = current.date
    measuredDays = earlier.count + 1
    let comparable = Set(baseline.groups?.keys.map { $0 } ?? []).intersection(
      current.groups?.keys.map { $0 } ?? [])
    comparableCategories = comparable.count
    let deltas = current.makeDeltas(since: baseline)
    let itemGrowth = current.growth(since: baseline)
    let seen = Set(baseline.items.map(\.id))
    let previousPaths = Set(baseline.items.map(\.path))
    categories = comparable.compactMap { group in
      guard let change = deltas[group], change > 0 else { return nil }
      let measured = itemGrowth.compactMap { item, delta -> Folder? in
        guard item.category == group, item.directoryInode != nil, delta > 0 else { return nil }
        return Folder(item: item, bytes: delta, firstSeen: false)
      }
      let new = current.items.compactMap { item -> Folder? in
        guard item.category == group, item.complete, item.directoryInode != nil,
          !seen.contains(item.id), !previousPaths.contains(item.path),
          let bytes = item.bytes, bytes > 0
        else { return nil }
        // A new breakdown beneath an old aggregate isn't evidence of a new folder.
        guard
          !baseline.items.contains(where: {
            $0.category == group && item.path.hasPrefix($0.path + "/")
          })
        else { return nil }
        return Folder(item: item, bytes: bytes, firstSeen: true)
      }
      let samples = (earlier + [current]).compactMap { snapshot in
        snapshot.groups?[group].map { Sample(date: snapshot.date, bytes: $0) }
      }
      return Category(
        name: group, change: change, samples: samples,
        folders: Array(
          (measured + new).sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
            .prefix(3)))
    }.sorted { $0.change == $1.change ? $0.name < $1.name : $0.change > $1.change }
  }
}
