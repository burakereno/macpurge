import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

extension ScanGroup {
  // Archive keys and item identifiers stay stable when the UI wording changes.
  var titleKey: String {
    switch self {
    case .xcode: "Xcode"
    case .packages: "Paket yöneticileri"
    case .apps: "Uygulama verileri ve önbellekleri"
    case .tools: "Geliştirici aracı verileri"
    case .logs: "Günlükler ve tanılama"
    default: rawValue
    }
  }

  var includedInQuickScan: Bool {
    [.xcode, .simulators, .packages, .projects, .logs].contains(self)
  }
}

extension ScanReport {
  /// A display-only snapshot. A category switches all of its rows and totals together.
  func retainingPending(_ pending: Set<ScanGroup>, from last: Self?) -> Self {
    guard !pending.isEmpty, let last, let scope, last.scope == scope else { return self }
    let keys = Set(pending.map(\.rawValue))
    func readings<T>(_ fresh: [String: T]?, _ old: [String: T]?) -> [String: T] {
      var values = fresh ?? [:]
      for key in keys { values[key] = old?[key] }
      return values
    }
    return Self(
      id: id, date: last.date, extended: extended, free: free, capacity: capacity,
      items: items.filter { !keys.contains($0.category) }
        + last.items.filter { keys.contains($0.category) },
      groups: readings(groups, last.groups), groupSafety: readings(groupSafety, last.groupSafety),
      measuredGroupBytes: readings(measuredGroupBytes, last.measuredGroupBytes), scope: scope)
  }
}

/// Updated as each location finishes, so opening a category only reads its five preview rows.
struct OverviewCategory {
  static let previewLimit = 5
  private(set) var locationCount = 0
  private(set) var pendingCount = 0
  private(set) var deviceCount = 0
  private(set) var hasReportItems = false
  private(set) var hasIncompleteItems = false
  private(set) var counts: [SafetyLevel: Int] = [:]
  private(set) var largest: [(root: ScanRoot, bytes: Int64)] = []

  mutating func register(_ root: ScanRoot) {
    locationCount += 1
    pendingCount += 1
    if root.device != nil { deviceCount += 1 }
  }

  mutating func record(_ result: RootSize, for root: ScanRoot) {
    pendingCount -= 1
    guard root.includedInInventory(result) else {
      locationCount -= 1
      return
    }
    guard result.state != .absent else { return }
    hasReportItems = true
    if result.state != .complete { hasIncompleteItems = true }
    let profiles: [StorageProfile] =
      root.device == nil
      ? [root.effectiveProfile(result)] : [.simulatorCache, .simulatorData]
    for profile in profiles {
      if let level = profile.assessment(for: result.state)?.level { counts[level, default: 0] += 1 }
    }
    guard result.measured, result.bytes > 0 else { return }
    let position =
      largest.firstIndex {
        result.bytes != $0.bytes
          ? result.bytes > $0.bytes : (root.title, root.id) < ($0.root.title, $0.root.id)
      } ?? largest.count
    guard position < Self.previewLimit else { return }
    largest.insert((root, result.bytes), at: position)
    if largest.count > Self.previewLimit { largest.removeLast() }
  }
}

enum CategorySize: Equatable {
  case waiting, outsideScope, empty, unavailable
  case bytes(Int64, lowerBound: Bool)

  static func read(_ group: ScanGroup, in report: ScanReport?, pending: Set<ScanGroup> = []) -> Self
  {
    guard let report else { return .waiting }
    if !report.extended && !group.includedInQuickScan { return .outsideScope }
    let key = group.rawValue
    if let complete = report.groups?[key] {
      if complete == 0, !report.items.contains(where: { $0.category == key }),
        report.groupSafety?[key] == nil,
        report.scope != nil
      {
        return .empty
      }
      return .bytes(complete, lowerBound: false)
    }
    if let measured = report.measuredGroupBytes?[key] { return .bytes(measured, lowerBound: true) }
    if pending.contains(group) { return .waiting }
    return report.items.contains { $0.category == key } ? .unavailable : .empty
  }

  var bytes: Int64? {
    if case .bytes(let amount, _) = self { return amount }
    return nil
  }

  var label: String {
    switch self {
    case .waiting: ReviewLanguage.text("Ölçülmedi")
    case .outsideScope: ReviewLanguage.text("Hızlı tarama dışında")
    case .empty: ReviewLanguage.text("Kayıt bulunamadı")
    case .unavailable: ReviewLanguage.text("Ölçülemedi")
    case .bytes(let bytes, let partial): (partial ? "≥ " : "") + byteLabel(bytes)
    }
  }
}

struct StorageCategoryIndex: View {
  let scan: LiveScan
  let report: ScanReport?
  let pending: Set<ScanGroup>
  let changes: [String: Int64]
  @State private var hoveredGroup: ScanGroup?
  let open: (ScanGroup) -> Void

  var body: some View {
    let groups = ScanGroup.allCases.sorted {
      let a = CategorySize.read($0, in: report, pending: pending).bytes ?? -1
      let b = CategorySize.read($1, in: report, pending: pending).bytes ?? -1
      if a != b { return a > b }
      return ReviewLanguage.text($0.titleKey).localizedStandardCompare(
        ReviewLanguage.text($1.titleKey)) == .orderedAscending
    }
    let groupsOfItems = Dictionary(grouping: (report?.items ?? []).filter {
      !scan.hiddenIDs.contains($0.id)
    }, by: \.category)
    let largest =
      groups.first.flatMap { CategorySize.read($0, in: report, pending: pending).bytes } ?? 0
    ScrollView {
      InventoryList(groups, id: \.self) { group in
          let reading = CategorySize.read(group, in: report, pending: pending)
          let items = groupsOfItems[group.rawValue] ?? []
          let cleanable = scan.distinctCleanups(items)
          let movable = cleanable.filter { scan.listMoveState($0) == .ready }
          let amounts = cleanable.reduce(into: [SafetyLevel: Int64]()) { sum, row in
            let action = scan.action(for: row)
            if let risk = action.risk { sum[risk, default: 0] += action.bytes }
          }
          Button {
            open(group)
          } label: {
            StorageCategoryRow(group: group, reading: reading, delta: changes[group.rawValue],
              amounts: amounts, selectable: scan.categorySelectionLabel(movable), largest: largest)
              .padding(.vertical, 10).padding(.horizontal, 12)
              .contentShape(Rectangle())
          }
          .buttonStyle(DisclosureRowStyle(isHovered: hoveredGroup == group))
          .accessibilityElement(children: .combine)
          .onHover { inside in
            if inside { hoveredGroup = group }
            else if hoveredGroup == group { hoveredGroup = nil }
          }

      }
    }
  }
}

/// Storage keeps its category index separate from the expandable cleanup lists.
private struct StorageCategoryRow: View {
  let group: ScanGroup
  let reading: CategorySize
  let delta: Int64?
  let amounts: [SafetyLevel: Int64]
  let selectable: String
  let largest: Int64

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      SymbolTile(symbol: group.symbol, tint: group.tint)
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline) {
          Text(ReviewLanguage.text(group.titleKey)).font(.headline)
            .lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 6)
          if let delta { SizeChange(bytes: delta) }
          InventoryAmount(text: reading.label, prominent: true)
            .foregroundStyle(reading.bytes == nil ? Color.secondary : .primary)
        }
        Text(selectable).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        if case .bytes(let total, _) = reading {
          SafetyBar(amounts: amounts, measured: total, largest: largest).padding(.top, 3)
          HStack(spacing: 14) {
            ForEach(SafetyLevel.allCases, id: \.self) { level in
              if let bytes = amounts[level] { SafetyAmount(level: level, bytes: bytes) }
            }
          }
        }
      }
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        .padding(.top, 3).accessibilityHidden(true)
    }
  }
}

struct SizeChange: View {
  let bytes: Int64
  var body: some View {
    Text((bytes > 0 ? "+" : "−") + byteLabel(abs(bytes)))
      .font(.caption).monospacedDigit().foregroundStyle(bytes > 0 ? Ink.gold : Ink.sea)
      .lineLimit(1).help(ReviewLanguage.text("Önceki eş kapsamlı taramaya göre değişim"))
  }
}

private struct SafetyBar: View {
  let amounts: [SafetyLevel: Int64]
  let measured: Int64
  let largest: Int64
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / CGFloat(max(largest, 1))
      let safe = min(measured, amounts[.safe] ?? 0)
      let review = min(measured - safe, amounts[.review] ?? 0)
      HStack(spacing: 0) {
        SafetyLevel.safe.color(in: scheme).frame(width: CGFloat(safe) * scale)
        SafetyLevel.review.color(in: scheme).frame(width: CGFloat(review) * scale)
        Color.secondary.opacity(0.4).frame(width: CGFloat(measured - safe - review) * scale)
      }
      .clipShape(Capsule())
      .frame(width: geometry.size.width, alignment: .leading)
      .background(.quaternary, in: Capsule())
    }
    .frame(height: 6)
    .accessibilityHidden(true)
  }
}

private struct SafetyAmount: View {
  let level: SafetyLevel
  let bytes: Int64
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let text = ReviewLanguage.text(level.rawValue) + " " + byteLabel(bytes)
    Label {
      Text(text).foregroundStyle(.secondary)
    } icon: {
      Image(systemName: level.symbol).foregroundStyle(level.color(in: scheme))
    }
    .labelStyle(.titleAndIcon).font(.caption).monospacedDigit()
    .accessibilityLabel(text)
  }
}
