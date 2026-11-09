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
    [.xcode, .simulators, .packages, .projects, .logs, .tools].contains(self)
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
      measuredGroupBytes: readings(measuredGroupBytes, last.measuredGroupBytes), scope: scope,
      applications: applications ?? last.applications)
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
      return .bytes(complete, lowerBound: !report.extended && group == .tools)
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

  static func combined(_ readings: [Self]) -> Self {
    let bytes = readings.compactMap(\.bytes)
    if !bytes.isEmpty {
      let incomplete = readings.contains {
        switch $0 {
        case .bytes(_, let lowerBound): lowerBound
        case .empty: false
        default: true
        }
      }
      return .bytes(bytes.reduce(0, +), lowerBound: incomplete)
    }
    if readings.contains(.waiting) { return .waiting }
    if readings.contains(.unavailable) { return .unavailable }
    if readings.contains(.outsideScope) { return .outsideScope }
    return .empty
  }
}

/// Storage navigation groups existing inventory categories without changing their archive keys.
enum StorageSection: String, CaseIterable {
  case development, applications, appCaches, intelligence, virtualization, files, system

  var titleKey: String {
    switch self {
    case .development: "Geliştirici araçları"
    case .applications: "Uygulamalar ve medya"
    case .appCaches: ScanGroup.appCaches.titleKey
    case .intelligence: "Yapay zekâ"
    case .virtualization: "Sanal makineler ve konteynerler"
    case .files: "Dosyalar"
    case .system: "Sistem ve yedekler"
    }
  }

  var icon: ScanGroup {
    switch self {
    case .development: .tools
    case .applications: .apps
    case .appCaches: .appCaches
    case .intelligence: .models
    case .virtualization: .machines
    case .files: .downloads
    case .system: .system
    }
  }

  var subgroups: [StorageSubgroup] {
    switch self {
    case .development: [.category(.xcode), .appleSimulators, .category(.android),
                        .category(.packages), .category(.tools), .category(.projects)]
    case .applications: [.applications, .appData, .media]
    case .appCaches: [.category(.appCaches)]
    case .intelligence: [.localModels, .aiTools]
    case .virtualization: [.category(.machines), .category(.docker)]
    case .files: [.category(.downloads), .category(.shared), .category(.other), .category(.trash)]
    case .system: [.category(.system), .category(.temp), .category(.logs),
                   .category(.backups), .category(.snapshots)]
    }
  }

  private static let groupsBySection = Dictionary(uniqueKeysWithValues: allCases.map {
    ($0, Set($0.subgroups.flatMap(\.groups)))
  })
  private static let sectionsByGroup = Dictionary(uniqueKeysWithValues: allCases.flatMap { section in
    (groupsBySection[section] ?? []).map { ($0.rawValue, section) }
  })

  static func containing(_ category: String) -> Self? { sectionsByGroup[category] }

  static func ordered(
    in report: ScanReport?, pending: Set<ScanGroup> = []
  ) -> [(section: Self, reading: CategorySize)] {
    allCases.map { ($0, $0.size(in: report, pending: pending)) }.sorted {
      let a = $0.1.bytes ?? -1
      let b = $1.1.bytes ?? -1
      return a == b ? $0.0.rawValue < $1.0.rawValue : a > b
    }
  }

  func size(in report: ScanReport?, pending: Set<ScanGroup> = []) -> CategorySize {
    CategorySize.combined((Self.groupsBySection[self] ?? []).map {
      CategorySize.read($0, in: report, pending: pending)
    })
  }
}

enum StorageSubgroup: Hashable {
  case category(ScanGroup), appleSimulators, applications, appData, media, localModels, aiTools

  var groups: [ScanGroup] {
    switch self {
    case .category(let group): [group]
    case .appleSimulators: [.simulators, .runtimes]
    case .applications, .appData, .media: [.apps]
    case .localModels, .aiTools: [.models]
    }
  }

  var titleKey: String {
    switch self {
    case .category(.tools): "Araç verileri ve önbellekleri"
    case .category(.projects): "Seçili projeler"
    case .category(let group): group.titleKey
    case .appleSimulators: "Apple simülatörleri"
    case .applications: "Uygulamalar"
    case .appData: ScanGroup.apps.titleKey
    case .media: "Medya kitaplıkları"
    case .localModels: "Yerel modeller"
    case .aiTools: "Yapay zekâ aracı verileri"
    }
  }

  static func containing(_ item: ReportItem) -> Self? {
    guard let group = ScanGroup(rawValue: item.category) else { return nil }
    switch group {
    case .simulators, .runtimes: return .appleSimulators
    case .apps:
      if item.evidence?.kind == .application || item.path == item.application?.path { return .applications }
      if ["Apple Loops", "Logic ses kitaplığı", "Steam oyunları"].contains(item.name) { return .media }
      return .appData
    case .models:
      if item.evidence?.rule.hasPrefix("ollama.") == true || item.name.hasPrefix("Ollama")
        || ["LM Studio", "PyTorch modelleri", "Chrome yerel modeli"].contains(item.name)
        || ["models--", "datasets--", "spaces--"].contains(where: item.name.hasPrefix)
      { return .localModels }
      return .aiTools
    default: return .category(group)
    }
  }
}

struct StorageCategoryIndex: View {
  let scan: LiveScan
  let report: ScanReport?
  let pending: Set<ScanGroup>
  let horizontalInset: CGFloat
  let open: (StorageSection) -> Void

  var body: some View {
    let sections = StorageSection.ordered(in: report, pending: pending)
    let groupsOfItems = Dictionary(grouping: (report?.items ?? []).filter {
      !scan.hiddenIDs.contains($0.id)
    }, by: { StorageSection.containing($0.category) })
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(sections, id: \.section) { section, reading in
          if section != sections.first?.section {
            Divider().padding(.horizontal, ListCardLayout.horizontalPadding)
          }
          let items = groupsOfItems[section] ?? []
          let movable = scan.distinctMoves(items)
          let safeBytes = scan.cleanupBytes(scan.safeMoves(items))
          let reviewBytes = scan.cleanupBytes(movable.filter { scan.action(for: $0).risk == .review })
          StorageCategoryLink(section: section, reading: reading, safeBytes: safeBytes,
            reviewBytes: reviewBytes, status: scan.categorySelectionLabel(movable)) {
            open(section)
          }
        }
      }
      .clipShape(.rect(cornerRadius: SurfaceCorners.radius))
      .listCardSurface(hovered: false)
      .padding(.horizontal, horizontalInset)
    }
  }
}

private struct StorageCategoryLink: View {
  let section: StorageSection
  let reading: CategorySize
  let safeBytes: Int64
  let reviewBytes: Int64
  let status: String
  let open: () -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var hovered = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 14) {
        Image(systemName: section.icon.symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 32, height: 32)
          .background(tileColor.gradient, in: .rect(cornerRadius: 9))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(ReviewLanguage.text(section.titleKey)).font(.headline).lineLimit(2)
          if safeBytes > 0 || reviewBytes > 0 {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 12) { safetyAmounts }
              VStack(alignment: .leading, spacing: 3) { safetyAmounts }
            }
          } else {
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if safeBytes > 0 { safeBadge }
        Text(reading.label)
          .font(reading.bytes == nil ? .callout : .title3.weight(.semibold))
          .monospacedDigit().lineLimit(1)
          .foregroundStyle(reading.bytes == nil ? Color.secondary : .primary)
          .fixedSize(horizontal: true, vertical: false)
        Image(systemName: "chevron.forward")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, ListCardLayout.horizontalPadding)
      .padding(.vertical, 12)
      .contentShape(.rect)
    }
    .buttonStyle(StorageCategoryLinkStyle(hovered: hovered))
    .accessibilityElement(children: .combine)
    .onHover { hovered = $0 }
  }

  @ViewBuilder private var safetyAmounts: some View {
    if safeBytes > 0 { SafetyAmount(level: .safe, bytes: safeBytes) }
    if reviewBytes > 0 { SafetyAmount(level: .review, bytes: reviewBytes) }
  }

  private var safeBadge: some View {
    let green = SafetyLevel.safe.color(in: scheme)
    return Text("\(byteLabel(safeBytes)) \(ReviewLanguage.text("Güvenli temizlenebilir"))")
      .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .foregroundStyle(green)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(green.opacity(0.12), in: .capsule)
      .help(ReviewLanguage.text("Estimated space after emptying Trash"))
  }

  private var tileColor: Color {
    switch section {
    case .development: Color(red: 0.25, green: 0.39, blue: 0.68)
    case .appCaches: Color(red: 0.19, green: 0.51, blue: 0.64)
    case .applications: Color(red: 0.63, green: 0.29, blue: 0.49)
    case .intelligence: Color(red: 0.49, green: 0.34, blue: 0.68)
    case .virtualization: Color(red: 0.15, green: 0.48, blue: 0.48)
    case .files: Color(red: 0.64, green: 0.36, blue: 0.16)
    case .system: Color(red: 0.33, green: 0.43, blue: 0.51)
    }
  }
}

private struct StorageCategoryLinkStyle: ButtonStyle {
  let hovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.045 : 0))
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
