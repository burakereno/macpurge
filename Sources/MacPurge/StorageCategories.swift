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
  let report: ScanReport?
  let pending: Set<ScanGroup>
  let changes: [String: Int64]
  let open: (ScanGroup) -> Void

  var body: some View {
    let groups = ScanGroup.allCases.sorted {
      let a = CategorySize.read($0, in: report, pending: pending).bytes ?? -1
      let b = CategorySize.read($1, in: report, pending: pending).bytes ?? -1
      if a != b { return a > b }
      return ReviewLanguage.text($0.titleKey).localizedStandardCompare(
        ReviewLanguage.text($1.titleKey)) == .orderedAscending
    }
    let largest =
      groups.first.flatMap { CategorySize.read($0, in: report, pending: pending).bytes } ?? 0
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(groups, id: \.self) { group in
          let reading = CategorySize.read(group, in: report, pending: pending)
          Button {
            open(group)
          } label: {
            CategoryStorageRow(
              group: group, reading: reading, delta: changes[group.rawValue],
              breakdown: report?.groupSafety?[group.rawValue], largest: largest
            )
            .padding(.vertical, 10).padding(.horizontal, 12).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .combine)
          if group != groups.last { Divider().padding(.leading, 58) }
        }
      }
    }
  }
}

private struct CategoryStorageRow: View {
  let group: ScanGroup
  let reading: CategorySize
  let delta: Int64?
  let breakdown: SafetyBreakdown?
  let largest: Int64

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      SymbolTile(symbol: group.symbol, tint: group.tint)
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline) {
          Text(ReviewLanguage.text(group.titleKey)).font(.headline)
          Spacer(minLength: 6)
          if let delta { SizeChange(bytes: delta) }
          Text(reading.label).font(.callout.weight(.semibold)).monospacedDigit()
            .foregroundStyle(reading.bytes == nil ? Color.secondary : .primary)
            .frame(width: 108, alignment: .trailing)
        }
        Text(ReviewLanguage.text(group.detail)).font(.caption).foregroundStyle(.secondary)
          .lineLimit(2)
        if case .bytes(let total, let partial) = reading {
          if let breakdown, breakdown.total == total {
            SafetyBar(breakdown: breakdown, largest: largest).padding(.top, 3)
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 16) { legend(breakdown, partial: partial) }.fixedSize()
              VStack(alignment: .leading, spacing: 3) { legend(breakdown, partial: partial) }
            }
          } else {
            Text(ReviewLanguage.text("Dağılım için yeniden tara")).font(.caption).foregroundStyle(
              .secondary)
          }
        }
      }
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        .padding(.top, 3).accessibilityHidden(true)
    }
  }

  @ViewBuilder private func legend(_ breakdown: SafetyBreakdown, partial: Bool) -> some View {
    SafetyAmount(level: .safe, bytes: breakdown.safe)
    SafetyAmount(level: .review, bytes: breakdown.review)
    if partial {
      Text(ReviewLanguage.text("Ölçülen kısım")).font(.caption2).foregroundStyle(.secondary)
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
  let breakdown: SafetyBreakdown
  let largest: Int64
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / CGFloat(max(largest, 1))
      HStack(spacing: 0) {
        SafetyLevel.safe.color(in: scheme).frame(width: CGFloat(breakdown.safe) * scale)
        SafetyLevel.review.color(in: scheme).frame(width: CGFloat(breakdown.review) * scale)
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
