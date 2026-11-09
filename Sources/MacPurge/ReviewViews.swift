import AppKit
import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct OverviewHighlights: View {
  let scan: LiveScan
  let report: ScanReport
  let items: [ReportItem]
  let previous: ScanReport?
  @Binding var selected: Set<String>

  var body: some View {
    let growth = Dictionary(uniqueKeysWithValues: report.growth(since: previous).map { ($0.0.id, $0.1) })
    VStack(alignment: .leading, spacing: 9) {
      SectionHead(title: "En büyük temizlik adayları")
      InventoryList(items) { item in
        let action = scan.action(for: item)
        InventoryMeasuredRow(scan: scan, item: item, selected: $selected,
          amount: byteLabel(action.bytes), delta: item.bytes == action.bytes ? growth[item.id] : nil)
      }
    }
  }
}

@MainActor enum AnonymousCard {
  static func copy(bytes: Int64, build: Int64) -> Bool {
    let card = VStack(alignment: .leading, spacing: 18) {
      Label("MacPurge", systemImage: "externaldrive").font(.headline)
      Text("Proje depolaması").font(.title2)
      Text(byteLabel(bytes)).font(.system(size: 42, weight: .bold))
      Text("Ölçülen derleme çıktıları · \(byteLabel(build))")
    }.padding(26).frame(width: 430, alignment: .leading).foregroundStyle(.white)
      .background(
        LinearGradient(colors: [.black, Ink.sea], startPoint: .leading, endPoint: .trailing))
    let renderer = ImageRenderer(content: card)
    renderer.scale = 2
    guard let image = renderer.nsImage else { return false }
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.writeObjects([image])
  }
}

enum SafetyFilter: String, CaseIterable {
  case all = "Tümü"
  case safe = "Güvenli"
  case review = "İncele"
  case unavailable = "Taşınamayanlar"
}

private struct StorageRoute {
  var showsItems = false
  var section: StorageSection?
  var sectionFilter: StorageSection?
  var subgroup: StorageSubgroup?
  var filter: SafetyFilter = .all

  static func items(in section: StorageSection?) -> Self {
    Self(showsItems: true, section: section)
  }
}

private enum StorageOrder: String, CaseIterable {
  case largest = "Largest first"
  case smallest = "Smallest first"
  case nameAscending = "Name (A–Z)"
  case nameDescending = "Name (Z–A)"
  case newest = "Most recently modified"
  case oldest = "Least recently modified"

  func precedes(_ lhs: StorageCardRow, _ rhs: StorageCardRow) -> Bool {
    let tie = lhs.id < rhs.id
    switch self {
    case .largest, .smallest:
      return ordered(lhs.bytes, rhs.bytes, ascending: self == .smallest, tie: tie)
    case .nameAscending, .nameDescending:
      let comparison = lhs.title.localizedStandardCompare(rhs.title)
      return comparison == .orderedSame ? tie
        : comparison == (self == .nameAscending ? .orderedAscending : .orderedDescending)
    case .newest, .oldest:
      return ordered(lhs.modified, rhs.modified, ascending: self == .oldest, tie: tie)
    }
  }

  private func ordered<Value: Comparable>(_ lhs: Value?, _ rhs: Value?, ascending: Bool, tie: Bool) -> Bool {
    guard let lhs else { return rhs == nil && tie }
    guard let rhs else { return true }
    return lhs == rhs ? tie : (ascending ? lhs < rhs : lhs > rhs)
  }
}

private struct StorageCardRow: Identifiable {
  let id: String
  let members: [ReportItem]
  var first: ReportItem { members[0] }
  var appCache: Bool { first.category == ScanGroup.appCaches.rawValue }
  var measurement: Bool { first.featuredMeasurement }
  var grouped: Bool { id != first.id }
  var title: String {
    if grouped && appCache && !measurement { return first.evidence?.owner ?? first.actionTitle }
    return first.actionTitle
  }
  var privateBytes: Int64? {
    let amounts = members.compactMap { $0.evidence?.privateAllocation?.privateBytes }
    return amounts.count == members.count ? amounts.reduce(0, +) : nil
  }
  var detail: String {
    ReviewLanguage.text(first.status == "unavailable" ? first.reason : first.evidence?.note ?? first.reason)
  }
  var caption: String {
    privateBytes.map { ReviewLanguage.format("%@ in private disk blocks", byteLabel($0)) } ?? detail
  }
  var bytes: Int64? {
    if members.count == 1 { return first.bytes }
    let measured = members.compactMap(\.bytes)
    return measured.isEmpty ? nil : measured.reduce(0, +)
  }
  var modified: Date? { members.count == 1 ? first.modified : members.compactMap(\.modified).max() }
  var partial: Bool { members.contains { !$0.complete } }

  static func make(_ items: [ReportItem], grouped: Bool, order: StorageOrder) -> [Self] {
    guard grouped else {
      return items.map { Self(id: $0.id, members: [$0]) }.sorted(by: order.precedes)
    }
    return Dictionary(grouping: items) { item in
      if item.category == ScanGroup.appCaches.rawValue || item.featuredMeasurement,
        let key = item.evidence?.rule {
        return key
      }
      return item.id
    }.map { group in
      Self(id: group.key, members: group.value.sorted {
        $0.bytes == $1.bytes ? $0.id < $1.id : ($0.bytes ?? -1) > ($1.bytes ?? -1)
      })
    }.sorted(by: order.precedes)
  }
}

struct StorageBrowser: View {
  let scan: LiveScan
  @Binding var selected: Set<String>
  let showsTrash: Bool
  let openCategories: () -> Void
  let openPlan: () -> Void
  @State private var route = StorageRoute()
  @State private var text = ""
  @State private var searchWidth: CGFloat = 320
  @FocusState private var searchFocused: Bool
  @State private var showsDocker = false
  private var section: StorageSection? { showsTrash ? .files : route.section ?? route.sectionFilter }
  private var subgroup: StorageSubgroup? { showsTrash ? .category(.trash) : route.subgroup }
  private var category: ScanGroup? {
    guard case .category(let group) = subgroup else { return nil }
    return group
  }
  private var filter: SafetyFilter { route.filter }
  private var listing: Bool { showsTrash || route.showsItems || !text.isEmpty }
  private var storageTitle: String {
    showsDocker ? "Docker manager" : showsTrash ? "Trash contents"
      : listing ? route.section?.titleKey ?? "Tüm öğeler" : "Depolama"
  }
  private var appCacheCategory: Bool { route.section == .appCaches }
  private var trashList: Bool { showsTrash || category == .trash }
  private var onlyCandidates: Bool { !showsTrash && route.section != nil }
  private var categoryOrder: Bool { showsTrash || route.section != nil }
  @State private var focus: String?
  @State private var sorting: StorageOrder = .largest
  @State private var inspecting = false
  @State private var pendingInspectorMoves: [ReportItem] = []
  private var report: ScanReport? { scan.storageReport }
  private var previous: ScanReport? {
    guard scan.phase == .finished, let report else { return nil }
    return report.previous(in: scan.history)
  }

  private func matchesFilters(_ item: ReportItem) -> Bool {
    let risk = scan.filterRisk(for: item)?.rawValue
    guard !scan.hiddenIDs.contains(item.id),
      !onlyCandidates || scan.wasCleanupCandidate(item) || item.featuredMeasurement,
      !item.featuredMeasurement || filter == .all || filter == .unavailable,
      section == nil || section == StorageSection.containing(item.category),
      subgroup == nil || subgroup == StorageSubgroup.containing(item),
      filter == .all || (filter == .unavailable ? scan.listMoveState(item) != .ready : risk == filter.rawValue)
    else { return false }
    return text.isEmpty
      || [
        item.name, item.actionTitle, item.category, item.path, item.application?.name ?? "",
        ScanGroup(rawValue: item.category).map { ReviewLanguage.text($0.titleKey) } ?? "",
        StorageSection.containing(item.category).map { ReviewLanguage.text($0.titleKey) } ?? "",
        StorageSubgroup.containing(item).map { ReviewLanguage.text($0.titleKey) } ?? "",
      ].contains { $0.localizedCaseInsensitiveContains(text) }
  }

  private var outsideFilter: Int {
    // A row that hasn't been measured in a progressive scan isn't hidden by a filter.
    (report?.items ?? []).filter { selected.contains($0.id) && !matchesFilters($0) }.count
  }

  var body: some View {
    let items = listing && !showsDocker ? (report?.items ?? []).filter(matchesFilters) : []
    let rows = StorageCardRow.make(items, grouped: categoryOrder, order: categoryOrder ? .largest : sorting)
    let movable = items.filter {
      if case .move = scan.action(for: $0) { return true }
      return false
    }
    let eligible = Set(movable.map(\.id))
    let checked = eligible.intersection(selected)
    let choices = scan.distinctMoves(movable.filter { checked.contains($0.id) })
    let selectionCount = rows.count { row in row.members.contains { checked.contains($0.id) } }
    let focusedRow = rows.first { $0.id == focus }
    WorkspacePage {
      header(choices)
    } content: { inset in
      VStack(alignment: .leading, spacing: 0) {
        Divider()
        GeometryReader { slot in
          Group {
            if showsDocker {
              DockerView(contentInset: inset, query: text)
            } else if report == nil && scan.phase.awaitsMeasurements {
              WorkspaceSkeleton(layout: listing ? .inventory : .categories,
                message: "Tarama hazırlanıyor", rows: listing ? 7 : 4)
                .padding(.horizontal, inset)
                .padding(.top, inset)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
            } else if listing {
              storageList(rows, eligible: eligible, contentInset: inset)
            } else {
              StorageCategoryIndex(
                scan: scan, report: report,
                pending: scan.phase == .running ? scan.pendingCategories : [],
                horizontalInset: inset
              ) { group in
                route = .items(in: group)
                focus = nil
              }
              .contentMargins(.vertical, inset, for: .scrollContent)
            }
          }
          .frame(width: slot.size.width, height: slot.size.height)
        }
        if !showsDocker {
          Divider()
          WorkspaceListBar {
            ViewThatFits(in: .horizontal) {
              HStack {
                footerLeading(items, count: rows.count, selectionCount: selectionCount).fixedSize()
                Spacer()
                footerActions(choices).fixedSize()
              }
              VStack(alignment: .leading, spacing: 6) {
                footerLeading(items, count: rows.count, selectionCount: selectionCount)
                footerActions(choices).frame(maxWidth: .infinity, alignment: .trailing)
              }
            }
          }
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { viewport in
      floor(min(340, max(160, viewport.size.width * 0.4)))
    } action: { searchWidth = $0 }
    .focusedSceneValue(\.focusWorkspaceSearch, { searchFocused = true })
    .onChange(of: route.subgroup) { focus = nil }
    .sheet(
      isPresented: $inspecting,
      onDismiss: {
        let items = pendingInspectorMoves
        pendingInspectorMoves = []
        if let item = items.first, scan.action(for: item).permanentOperation != nil {
          scan.cleanup.reviewPermanentCleanup(item, scan: scan)
        } else if !items.isEmpty {
          scan.cleanup.prepare(items, scan: scan, explicit: true)
        }
      }
    ) {
      if let row = focusedRow, row.grouped {
        groupInspector(row)
      } else if let item = focusedRow?.first ?? report?.items.first(where: { $0.id == focus }) {
        let delta = report?.growth(since: previous).first { $0.0.id == item.id }?.1
        ItemInspector(scan: scan, item: item, delta: delta) {
          pendingInspectorMoves = [item]
          inspecting = false
        }
      }
    }
  }

  private var searchField: some View {
    WorkspaceSearchField(prompt: "Öğe, kategori veya konum ara", text: $text, focused: $searchFocused,
      height: WorkspaceControlLayout.toolbarHeight)
  }

  private func header(_ choices: [ReportItem]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      WorkspaceHeadingRow(title: Text(ReviewLanguage.text(storageTitle))) {
        searchField.frame(minWidth: 160, idealWidth: searchWidth, maxWidth: searchWidth)
      }
      VStack(alignment: .leading, spacing: 12) {
        if showsDocker {
          WorkspaceBackButton(title: "Docker") { showsDocker = false }
        } else {
          if !listing {
            Button("Tüm öğeler") { route = .items(in: nil) }
              .workspaceButton(.secondary)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          if scan.phase == .running { ScanStatus(scan: scan) }
          if listing { filters(choices) }
        }
      }
      .padding(.bottom, WorkspaceLayout.headerVerticalInset)
    }
  }

  private func footerLeading(_ items: [ReportItem], count: Int, selectionCount: Int) -> some View {
    HStack(spacing: 12) {
      if listing && !trashList {
        SafeTrashButton(scan: scan, group: category,
          items: items.filter { $0.safety == SafetyLevel.safe.rawValue })
      }
      footerSummary(count, selectionCount: selectionCount)
    }
  }

  @ViewBuilder private func footerSummary(_ count: Int, selectionCount: Int) -> some View {
    if listing {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(count) öğe · \(selectionCount) seçim")
        if !selected.isEmpty && (section != nil || filter != .all || !text.isEmpty) {
          let hiddenSelections = outsideFilter
          if hiddenSelections > 0 {
            Text(ReviewLanguage.format("%lld seçim filtre dışında", Int64(hiddenSelections)))
          }
        }
      }.font(.caption).foregroundStyle(.secondary)
    } else if let report {
      HStack {
        Text(ReviewLanguage.text(report.extended ? "Ayrıntılı tarama" : "Hızlı tarama"))
          .font(.caption.weight(.semibold))
        Text(report.date, format: .dateTime.day().month().hour().minute())
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func footerActions(_ choices: [ReportItem]) -> some View {
    HStack {
      if listing && !appCacheCategory && !trashList {
        cleanSelected(choices)
      }
      Button("Alan planını aç", action: openPlan)
        .workspaceButton(.secondary)
        .disabled(scan.phase == .running)
    }
  }

  private func filters(_ choices: [ReportItem]) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        storageBackButton
        Spacer()
        filterControls
        categoryActions(choices).fixedSize()
      }
      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 12) {
          storageBackButton
          Spacer()
          categoryActions(choices).fixedSize()
        }
        filterControls
      }
    }
  }

  private var storageBackButton: some View {
    WorkspaceBackButton(title: "Kategoriler") {
      if showsTrash {
        openCategories()
      } else {
        route = StorageRoute()
        text = ""
        focus = nil
      }
    }
  }

  private var filterControls: some View {
    HStack(spacing: 12) {
      riskPicker.fixedSize()
      storagePickers
    }
  }

  @ViewBuilder private func categoryActions(_ choices: [ReportItem]) -> some View {
    if category == .other {
      Button("Taranacak klasörü seç…", action: scan.chooseLargeFolders)
        .workspaceButton(.secondary)
    }
    if category == .docker || (section == .virtualization && subgroup == nil) {
      Button("Docker manager") { showsDocker = true }
        .workspaceButton(.secondary)
    }
    if appCacheCategory {
      cleanSelected(choices)
    }
  }

  private func cleanSelected(_ choices: [ReportItem]) -> some View {
    let title = ReviewLanguage.text("Clean selected…")
      + (choices.isEmpty ? "" : " · " + byteLabel(scan.cleanupBytes(choices)))
    return MainAction(title: title, symbol: "trash") {
      scan.cleanup.prepare(choices, scan: scan, explicit: true)
    }
    .monospacedDigit()
    .disabled(choices.isEmpty || scan.cleanup.busy)
    .help("Çöp’e taşımayı incele…")
  }

  private var riskPicker: some View {
    let choices = onlyCandidates ? [.all, .safe, .review] : SafetyFilter.allCases
    return WorkspaceTabs(label: "Risk", choices: choices, selection: $route.filter) {
      Text(ReviewLanguage.text($0.rawValue))
    }
  }

  @ViewBuilder private var storagePickers: some View {
    if !showsTrash {
      if route.section == nil {
        let sections = StorageSection.ordered(in: report, pending: scan.pendingCategories).map(\.section)
        WorkspacePicker(label: "Kategori", choices: [nil] + sections.map(Optional.some),
          selection: Binding(get: { route.sectionFilter }, set: {
            route.sectionFilter = $0
            route.subgroup = nil
            focus = nil
          }), appearance: .button) { section in
          Text(ReviewLanguage.text(section?.titleKey ?? "Tüm kategoriler"))
        }
      }
      if let section, section.subgroups.count > 1 { subgroupPicker(in: section) }
    }
  }

  private func subgroupPicker(in section: StorageSection) -> some View {
    let totals = (report?.items ?? []).reduce(into: [StorageSubgroup: Int64]()) { sums, item in
      guard StorageSection.containing(item.category) == section,
        let subgroup = StorageSubgroup.containing(item), let bytes = item.bytes
      else { return }
      sums[subgroup, default: 0] += bytes
    }
    let groups = section.subgroups.sorted { lhs, rhs in
      let a = totals[lhs] ?? -1
      let b = totals[rhs] ?? -1
      return a == b ? lhs.titleKey < rhs.titleKey : a > b
    }
    return WorkspacePicker(label: "Alt grup", choices: [nil] + groups.map(Optional.some),
      selection: $route.subgroup, appearance: .button) { group in
      Text(ReviewLanguage.text(group?.titleKey ?? "Tümü"))
    }
  }

  private func storageList(_ rows: [StorageCardRow], eligible: Set<String>, contentInset: CGFloat) -> some View {
    StorageCards(scan: scan, rows: rows, eligible: eligible, selected: selected, showsSelection: !trashList,
      contentInset: contentInset, toggle: toggleSelection, details: { row in
        focus = row.id
        inspecting = true
      }, hide: { row in
        for item in row.members {
          scan.hide(item)
          selected.remove(item.id)
        }
      })
      .overlay { if rows.isEmpty { emptyStorageList } }
      .workspaceListControls { storageListControls(eligible) }
  }

  private func storageListControls(_ eligible: Set<String>) -> some View {
    let selection = InventorySelection(eligible: eligible, selected: selected)
    return HStack {
      if !trashList {
        Button { toggleSelection(eligible) } label: {
          HStack(spacing: InventoryLayout.controlSpacing) {
            selection.mark
            Text("Select all").font(.callout.weight(.medium))
          }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityValue(ReviewLanguage.text(selection.label))
        .disabled(eligible.isEmpty || scan.cleanup.busy)
      }
      Spacer()
      if categoryOrder {
        Label("Largest first", systemImage: "arrow.up.arrow.down")
          .font(.caption.weight(.medium)).foregroundStyle(.secondary)
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(.primary.opacity(0.06), in: Capsule())
      } else {
        Menu {
          Picker("Sort by", selection: $sorting) {
            ForEach(StorageOrder.allCases, id: \.self) { order in
              Text(ReviewLanguage.text(order.rawValue)).tag(order)
            }
          }
          .pickerStyle(.inline)
        } label: {
          Label(ReviewLanguage.text(sorting.rawValue), systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel(Text("Sort by"))
        .accessibilityValue(ReviewLanguage.text(sorting.rawValue))
      }
    }
  }

  private func toggleSelection(_ eligible: Set<String>) {
    guard scan.phase == .finished, !scan.cleanup.busy else { return }
    if eligible.isSubset(of: selected) {
      selected.subtract(eligible)
    } else {
      selected.formUnion(eligible)
    }
  }

  private func groupInspector(_ row: StorageCardRow) -> some View {
    let moves = scan.distinctMoves(row.members)
    return VStack(alignment: .leading, spacing: 15) {
      SectionHead(title: row.title, note: row.appCache ? ScanGroup.appCaches.titleKey : ScanGroup.tools.titleKey)
      Text(row.detail).foregroundStyle(.secondary)
      LabeledContent("Ölçüm", value: row.bytes.map(byteLabel) ?? "—")
      if row.appCache {
        if let modified = row.modified {
          LabeledContent("Değişiklik", value: modified.reviewDate(date: .abbreviated, time: .omitted))
        }
        let ids = Set(row.members.map(\.id))
        let deltas = report?.growth(since: previous).filter { ids.contains($0.0.id) }.map { $0.1 } ?? []
        if !deltas.isEmpty { LabeledContent("Fark") { SizeChange(bytes: deltas.reduce(0, +)) } }
      }
      if let privateBytes = row.privateBytes {
        LabeledContent("Private disk blocks", value: byteLabel(privateBytes))
      }
      if !row.measurement {
        LabeledContent("Güvenli", value: byteLabel(scan.cleanupBytes(scan.safeMoves(moves))))
      }
      ScrollView {
        InventoryList(row.members) { item in
          if row.measurement {
            let path = URL(fileURLWithPath: item.path)
            InventoryReadout(title: row.appCache ? path.lastPathComponent
              : path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
              amount: item.bytes.map(byteLabel) ?? "—", symbol: "folder", subtitle: item.shortPath,
              location: item.bytes == nil ? nil : path)
              .inventoryRowCard()
          } else {
            InventoryMeasuredRow(scan: scan, item: item, selected: $selected,
              title: URL(fileURLWithPath: item.path).lastPathComponent, caption: item.shortPath)
          }
        }
      }.frame(maxHeight: 360)
      HStack {
        if !row.measurement {
          Button("Çöp’e taşımayı incele…") {
            pendingInspectorMoves = moves
            inspecting = false
          }.workspaceButton(.secondary).disabled(moves.isEmpty || scan.cleanup.busy)
        }
        Spacer()
        Button("Bitti") { inspecting = false }.workspaceButton().keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(minWidth: 520, idealWidth: 600)
  }

  @ViewBuilder private var emptyStorageList: some View {
    if let section, isOutsideScope(section) {
      ContentUnavailableView {
        Label("Hızlı tarama dışında", systemImage: category?.symbol ?? section.icon.symbol)
      } actions: {
        Button("Ayrıntılı tarama", action: scan.startDetailed)
          .workspaceButton()
          .disabled(scan.phase == .running)
      }
    } else {
      ContentUnavailableView(
        "Sonuç yok", systemImage: "magnifyingglass",
        description: Text(onlyCandidates ? "No cleanup actions are available for this filter." :
          "Filtreyi değiştir veya taramanın tamamlanmasını bekle."))
    }
  }

  private func isOutsideScope(_ section: StorageSection) -> Bool {
    if let subgroup {
      return CategorySize.combined(subgroup.groups.map { CategorySize.read($0, in: report) }) == .outsideScope
    }
    return section.size(in: report) == .outsideScope
  }
}

private struct StorageCards: View {
  @Environment(\.workspaceListLayout) private var layout
  let scan: LiveScan
  let rows: [StorageCardRow]
  let eligible: Set<String>
  let selected: Set<String>
  let showsSelection: Bool
  let contentInset: CGFloat
  let toggle: (Set<String>) -> Void
  let details: (StorageCardRow) -> Void
  let hide: (StorageCardRow) -> Void
  @FocusState private var keyboardRow: String?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: layout.cardSpacing) {
          ForEach(rows) { row in
            let ids = Set(row.members.map(\.id)).intersection(eligible)
            let action = scan.action(for: row.first)
            let explanation = row.grouped ? row.caption : scan.actionDescription(row.first)
            StorageItemCard(row: row, selection: InventorySelection(eligible: ids, selected: selected),
              showsSelection: showsSelection, selectable: !ids.isEmpty, busy: scan.cleanup.busy,
              action: action, explanation: explanation,
              keyboardRow: $keyboardRow, toggle: { toggle(ids) }, details: { details(row) }) {
                if action.permanentOperation != nil {
                  ItemTrashButton(scan: scan, item: row.first)
                    .focusEffectDisabled()
                } else {
                  Button { details(row) } label: {
                    Image(systemName: "info.circle").font(.callout).foregroundStyle(.tertiary)
                      .frame(width: InventoryLayout.actionWidth, height: InventoryLayout.actionWidth)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .focusEffectDisabled()
                  .accessibilityLabel(ReviewLanguage.text("Ayrıntıları göster") + " · " + row.title)
                  .help(action.availability.explanation ?? ReviewLanguage.text("Ayrıntıları göster"))
                }
              }
              .contextMenu {
                Button("Ayrıntıları göster") { details(row) }
                if row.members.count == 1, row.first.bytes != nil {
                  Button("Finder’da aç") {
                    InventoryLocation.open(URL(fileURLWithPath: row.first.path))
                  }
                }
                if !ids.isEmpty {
                  Button("Çöp’e taşı…") {
                    scan.cleanup.prepare(scan.distinctMoves(row.members.filter { ids.contains($0.id) }),
                      scan: scan, explicit: true)
                  }.disabled(scan.cleanup.busy)
                }
                Button("Önerilerden gizle") { hide(row) }
              }
          }
        }
        .padding(.horizontal, contentInset)
      }
      .contentMargins(.top, contentInset, for: .scrollContent)
      .onKeyPress(keys: [.upArrow, .downArrow]) { press in
        guard let keyboardRow, let index = rows.firstIndex(where: { $0.id == keyboardRow }) else { return .ignored }
        let next = index + (press.key == .downArrow ? 1 : -1)
        guard rows.indices.contains(next) else { return .handled }
        let id = rows[next].id
        proxy.scrollTo(id)
        self.keyboardRow = id
        return .handled
      }
    }
  }
}

private struct StorageItemCard<TrailingAction: View>: View {
  let row: StorageCardRow
  let selection: InventorySelection
  let showsSelection: Bool
  let selectable: Bool
  let busy: Bool
  let action: CleanupAction
  let explanation: String
  let keyboardRow: FocusState<String?>.Binding
  let toggle: () -> Void
  let details: () -> Void
  @ViewBuilder let trailingAction: TrailingAction
  @State private var hovered = false
  @ScaledMetric(relativeTo: .caption) private var badgeWidth: CGFloat = 128

  var body: some View {
    HStack(spacing: 0) {
      Button(action: selectable ? toggle : details) {
        HStack(spacing: 12) {
          if selectable {
            selection.mark
          } else if showsSelection {
            Color.clear.frame(width: InventoryLayout.selectionWidth).accessibilityHidden(true)
          }
          StorageItemIcon(path: row.appCache ? row.first.application?.path : nil,
            rule: row.first.evidence?.rule, group: ScanGroup(rawValue: row.first.category))
          VStack(alignment: .leading, spacing: 5) {
            Text(row.title).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(explanation).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let age = row.first.age {
              let prefix = row.partial ? "≥ " : ""
              Text(ReviewLanguage.format("Last 72 hours %@ · Older %@",
                prefix + byteLabel(age.recent), prefix + byteLabel(age.older)))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 14) {
            Group {
              if !row.measurement, action.risk == .safe {
                SafetyBadge(level: .safe, titleKey: "Safe to clean")
              } else {
                ActionBadge(action: row.measurement ? .measurement(row.detail) : action, item: row.first)
              }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: badgeWidth, alignment: .leading)
            let amount = row.bytes.map { (row.partial ? "≥ " : "") + byteLabel($0) } ?? "—"
            InventoryAmount(text: amount, prominent: true)
          }
          .fixedSize()
        }
        .padding(.leading, ListCardLayout.horizontalPadding)
        .padding(.trailing, 4)
        .padding(.vertical, ListCardLayout.verticalPadding)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable()
      .focusEffectDisabled()
      .focused(keyboardRow, equals: row.id)
      .onKeyPress(.return) { details(); return .handled }
      .disabled(selectable && busy)
      .accessibilityValue(selectable ? ReviewLanguage.text(selection.label) : "")
      .accessibilityHint(ReviewLanguage.text(selectable ? "Toggle selection" : "Ayrıntıları göster"))
      .help(row.measurement ? row.detail : action.availability.explanation ?? explanation)

      trailingAction
        .frame(width: InventoryLayout.actionWidth)
        .padding(.trailing, ListCardLayout.horizontalPadding)
    }
    .detailCardSurface(highlighted: hovered)
    .onHover { hovered = $0 }
  }

}

private struct StorageItemIcon: View {
  let path: String?
  let rule: String?
  let group: ScanGroup?
  var body: some View {
    DetailCardIcon(symbol: fallback, path: path)
  }

  private var fallback: String {
    switch rule {
    case "app-cache.com.openai.codex", "app-cache.com.openai.chat",
         "app-cache.com.anthropic.claudefordesktop": "sparkles"
    case "app-cache.com.figma.Desktop", "app-cache.com.framer.electron": "square.on.square"
    case "app-cache.com.google.Chrome", "app-cache.com.brave.Browser",
         "app-cache.org.mozilla.firefox", "app-cache.org.chromium.Chromium",
         "app-cache.com.microsoft.edgemac", "app-cache.company.thebrowser.Browser",
         "app-cache.company.thebrowser.dia", "app-cache.com.vivaldi.Vivaldi": "globe"
    case "app-cache.com.tinyspeck.slackmacgap", "app-cache.com.hnc.Discord": "bubble.left.and.bubble.right"
    case "app-cache.ru.keepcoder.Telegram", ProtectedCacheInventory.telegramRule: "paperplane"
    case "app-cache.com.spotify.client": "music.note"
    case "app-cache.us.zoom.xos": "video"
    default: group?.symbol ?? "folder"
    }
  }
}

extension ReportItem {
  fileprivate var featuredMeasurement: Bool {
    guard evidence?.inspectionOnly == true else { return false }
    return evidence?.rule == ProtectedCacheInventory.coreDeviceRule
      || evidence?.rule == ProtectedCacheInventory.telegramRule
  }
}

private struct ManagingTool {
  let name: String
  let bundleID: String
  let guidance: String

  var applicationURL: URL? {
    if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return installed
    }
    for domain: FileManager.SearchPathDomainMask in [.localDomainMask, .userDomainMask] {
      if let apps = FileManager.default.urls(for: .applicationDirectory, in: domain).first {
        let url = apps.appending(path: name + ".app")
        if Bundle(url: url)?.executableURL != nil { return url }
      }
    }
    return nil
  }

  init?(_ item: ReportItem) {
    switch ScanGroup(rawValue: item.category) {
    case .docker:
      (name, bundleID, guidance) = (
        "Docker Desktop", "com.docker.docker",
        "İmajları ve kullanılmayan verileri Docker Desktop’ta inceleyebilirsin."
      )
    case .android:
      (name, bundleID, guidance) = (
        "Android Studio", "com.google.android.studio",
        "SDK bileşenleri için SDK Manager’ı, emülatörler için Device Manager’ı aç."
      )
    case .models where item.name.hasPrefix("Ollama"):
      (name, bundleID, guidance) = (
        "Ollama", "com.electron.ollama",
        "Modelleri Ollama’da veya ollama list ile inceleyebilirsin."
      )
    case .models where item.name == "LM Studio":
      (name, bundleID, guidance) = (
        "LM Studio", "com.lmstudio.lmstudio",
        "İndirilen modelleri LM Studio’daki My Models bölümünde inceleyebilirsin."
      )
    case .models where item.name == "Chrome yerel modeli":
      (name, bundleID, guidance) = (
        "Google Chrome", "com.google.Chrome",
        "Yerel modelin kullanımını Chrome’da inceleyebilirsin."
      )
    default: return nil
    }
  }
}

struct RuntimeDetails: View {
  let usage: RuntimeUsage
  var compact = false
  @State private var openError: String?

  private var deviceRows: some View {
    InventoryRows(usage.devices, id: \.id) { device in
      InventoryReadout(title: device.name, amount: String(device.id.uuidString.prefix(8)),
        symbol: "iphone")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      InventoryReadout(title: ReviewLanguage.text("Son kullanım"),
        amount: usage.lastUsed?.reviewDate(date: .abbreviated, time: .omitted)
          ?? ReviewLanguage.text("Bildirilmedi"), symbol: "clock")
      HStack(spacing: 6) {
        Text("Bağlı cihazlar").font(.headline)
        if !usage.devices.isEmpty {
          Text(usage.devices.count, format: .number).monospacedDigit().foregroundStyle(.secondary)
        }
      }
      if usage.multipleImages {
        Text(
          "Aynı sürümün birden fazla imajı var. Cihazlar sürümle eşleşiyor; kullandıkları imaj doğrulanamadı."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if !usage.deviceListComplete {
        Text("Cihaz listesinin tamamı doğrulanamadı.").font(.caption).foregroundStyle(.secondary)
      } else if usage.devices.isEmpty {
        Text("Bağlı cihaz yok.").foregroundStyle(.secondary)
      }
      if !usage.devices.isEmpty {
        if compact {
          ViewThatFits(in: .vertical) {
            deviceRows.fixedSize(horizontal: false, vertical: true)
            ScrollView { deviceRows.padding(.trailing, 6) }
          }.frame(maxHeight: 128, alignment: .top)
        } else {
          deviceRows
        }
      }
      if let xcode = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.dt.Xcode")
      {
        Button("Xcode’u aç") {
          Task {
            do {
              _ = try await NSWorkspace.shared.openApplication(at: xcode, configuration: .init())
            } catch { openError = error.localizedDescription }
          }
        }
        .workspaceButton(.secondary)
        .help("Runtime’ları Xcode → Settings → Components bölümünde yönetebilirsin.")
      }
      if let openError { Text(openError).font(.caption) }
    }
  }
}

struct ItemInspector: View {
  let scan: LiveScan
  let item: ReportItem
  var delta: Int64? = nil
  let prepare: () -> Void
  private var decision: CleanupAction { scan.action(for: item) }
  @Environment(\.dismiss) private var dismiss
  @State private var openError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      SectionHead(
        title: item.actionTitle, note: ScanGroup(rawValue: item.category)?.titleKey ?? item.category)
      ActionBadge(action: decision, item: item)
      Text(decision.availability.explanation ?? scan.actionDescription(item))
        .fixedSize(horizontal: false, vertical: true)
      if let workspace = item.workspace {
        LabeledContent("Xcode projesi", value: workspace).textSelection(.enabled)
      }
      LabeledContent("Ölçüm", value: item.bytes.map(byteLabel) ?? ReviewLanguage.text("Bilinmiyor"))
      if let delta { LabeledContent("Fark") { SizeChange(bytes: delta) } }
      LabeledContent(
        "Kaynak",
        value: ReviewLanguage.text(item.estimated
          ? "Aracın bildirdiği boyut"
          : (item.status == "partial" ? "Kısmi disk ölçümü" : "Dosya sistemi")))
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          let location = URL(filePath: item.path)
          if item.category == ScanGroup.packages.rawValue,
            PnpmStoreAudit.supports(location, home: FileManager.default.homeDirectoryForCurrentUser)
          {
            PnpmStoreDetails(store: location, projects: scan.projects, excludedFolders: scan.excludedFolders)
          }
          Surface {
            InventoryItemDetails(item: item).padding(.horizontal, SurfaceCorners.rowInset)
          }
        }
      }.frame(maxHeight: 300)
      if let tool = ManagingTool(item) {
        Divider()
        Text(ReviewLanguage.text(tool.guidance)).font(.callout).foregroundStyle(.secondary)
        if let url = tool.applicationURL {
          Button(String(format: ReviewLanguage.text("%@ uygulamasını aç"), tool.name)) {
            Task {
              do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
              } catch { openError = error.localizedDescription }
            }
          }
          .workspaceButton(.secondary)
        }
        if let openError { Text(openError).font(.caption) }
      } else if ScanGroup(rawValue: item.category) == .models {
        Text(
          ReviewLanguage.text(
            "Bu depoyu, modeli indiren araçtan yönetebilirsin. Paylaşılan model dosyaları birden fazla projede kullanılabilir."
          )
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        if !item.estimated && item.status != "unavailable" {
          Button("Finder’da göster") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
          }
          .workspaceButton(.secondary)
        }
        ItemTrashButton(scan: scan, item: item, showActionTitle: true, beforePreview: prepare)
        Spacer()
        Button("Bitti") { dismiss() }
          .workspaceButton()
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(minWidth: 450, idealWidth: 540)
  }
}

private struct PnpmStoreDetails: View {
  let store: URL
  let projects: [URL]
  let excludedFolders: [URL]
  @State private var request: UUID?
  @State private var result: PnpmStoreAudit?
  @State private var measuring = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(ReviewLanguage.text("pnpm store references")).font(.headline)
      if let result {
        if result.versions.contains(where: { $0.unmatchedBytes != nil }) {
          LabeledContent(
            ReviewLanguage.text("Unmatched in scanned records"), value: byteLabel(result.unmatchedBytes))
        }
        InventoryRows(result.versions) { version in
          InventoryReadout(title: version.id, amount: version.unmatchedBytes.map(byteLabel) ?? "—",
            symbol: "externaldrive", subtitle: ReviewLanguage.text(version.unmatchedBytes == nil
              ? "Could not measure this version" : "Unmatched in scanned records"))
        }
        Text(ReviewLanguage.format(
          "Scope: %lld selected folders, %lld registered locations, %lld project lockfiles and %lld installed lockfiles.",
          Int64(result.projectScopes), Int64(result.registeredProjects), Int64(result.wantedLocks),
          Int64(result.installedLocks)))
          .font(.caption).foregroundStyle(.secondary)
        if result.incomplete {
          Text(ReviewLanguage.text("Some locations or formats could not be read. The result covers the records that were read."))
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(ReviewLanguage.text("For reference only. The estimated space from safe cleanup is calculated separately."))
          .font(.caption).foregroundStyle(.secondary)
      } else if failed {
        Text(ReviewLanguage.text("The pnpm store could not be measured."))
          .font(.caption).foregroundStyle(.secondary)
      }
      if measuring {
        ProgressView(ReviewLanguage.text("Reading pnpm indexes and lockfiles…"))
          .controlSize(.small)
      } else {
        Button(ReviewLanguage.text(result == nil ? "Measure pnpm references" : "Measure again")) {
          measuring = true
          failed = false
          request = UUID()
        }
        .workspaceButton(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .task(id: request) {
      guard request != nil else { return }
      let exclusions = ScanExclusions(paths: excludedFolders.map(\.path))
      do {
        result = try await PnpmStoreAudit.read(store: store, projects: projects, exclusions: exclusions)
      } catch is CancellationError {
        return
      } catch {
        result = nil
        failed = true
      }
      measuring = false
    }
  }
}

struct SpacePreview: View {
  let scan: LiveScan
  @Binding var selected: Set<String>
  @State private var target = 20
  var body: some View {
    Page {
      PageTitle(title: "Alan planı")
    } controls: {
      if let report = scan.report {
        WorkspaceListBar {
          HStack {
            Text("Hedef").accessibilityHidden(true)
            WorkspacePicker(label: "Hedef", choices: [1, 5, 10, 20, 50, 100], selection: $target) {
              Text("\($0) GB")
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Button("Adayları öner") {
              let goal = Int64(target) * 1_000_000_000
              let regrowth = scan.historyEnabled ? scan.regrownFolders ?? [] : []
              selected = Set(
                report.plan(
                  target: goal, excluding: scan.hiddenIDs, moveStates: scan.moveStates,
                  regrowth: regrowth, actionBytes: scan.actions.mapValues(\.bytes)
                )
                .map(\.id))
            }
            .workspaceButton()
            .disabled(scan.phase != .finished || !scan.actions.values.contains { $0.risk == .safe })
            .help(
              "72 saat içinde eski boyutunun en az yarısına dönen klasörler son sırada önerilir. Yeterli geçmiş yoksa en büyük güvenli öğeler önce gelir."
            )
          }
        }
      }
    } content: {
      if let report = scan.report {
        let selectedRows = scan.explicitSelection(selected, in: report)
        let choices = scan.distinctMoves(selectedRows)
        let bytes = scan.cleanupBytes(choices)
        let goal = Int64(target) * 1_000_000_000
        Surface {
          VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: Double(min(bytes, goal)), total: Double(goal)).tint(Ink.sea)
            Text("Seçilen \(byteLabel(bytes)) · Hedef \(byteLabel(goal))").font(.headline)
            if bytes < goal {
              Text(
                "Hedefe \(byteLabel(goal-bytes)) eksik. İncele etiketli veriler otomatik seçilmez."
              ).foregroundStyle(.secondary)
            }
          }.padding(16)
        }
        SectionHead(title: "Seçilen öğeler", note: "\(choices.count)")
        if choices.isEmpty {
          Note(
            symbol: "scope",
            text: "Adayları öner düğmesiyle veya Depolama tablosundan bir seçim oluştur.")
        }
        if !choices.isEmpty {
          InventoryList(choices) { row in
            InventoryMeasuredRow(scan: scan, item: row, selected: $selected,
              amount: byteLabel(scan.action(for: row).bytes), removeFromPlan: { selected.remove(row.id) })
          }
        }
        CleanupControls(scan: scan, choices: selectedRows)
      } else if scan.phase.awaitsMeasurements {
        WorkspaceSkeleton(layout: .inventory, message: "Ölçüm bekleniyor", rows: 4)
      } else {
        ContentUnavailableView("Ölçüm bekleniyor", systemImage: "scope")
      }
    }
  }
}
