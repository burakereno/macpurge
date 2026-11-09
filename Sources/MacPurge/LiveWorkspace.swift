import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum LiveSection: Hashable {
  case overview, storage, uninstall, duplicates, projects, plan, settings, trash
}

struct LiveWorkspace: View {
  @Environment(\.scenePhase) private var scenePhase
  let scan: LiveScan
  @Binding var section: LiveSection
  @State private var selectedIDs: Set<String> = []
  @State private var showsMoveResult = false

  var body: some View {
    @Bindable var cleanup = scan.cleanup
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 165, ideal: 194, max: 230)
        .toolbar(removing: .sidebarToggle)
    } detail: {
      Group {
        switch section {
        case .settings: ControlSettings(scan: scan)
        case .overview:
          LiveOverview(scan: scan, selected: $selectedIDs) {
            section = .storage
          }
        case .storage, .trash:
          StorageBrowser(scan: scan, selected: $selectedIDs, showsTrash: section == .trash,
            openCategories: { section = .storage }, openPlan: { section = .plan })
            .id(section)
        case .uninstall: ApplicationUninstallView(scan: scan)
        case .duplicates: DuplicatesView(scan: scan)
        case .projects:
          ProjectRootsView(scan: scan)
        case .plan: SpacePreview(scan: scan, selected: $selectedIDs)
        }
      }
      .modifier(WorkspaceDetailSurface())
      .environment(\.workspaceHeaderControls, .scan(scan))
      .ignoresSafeArea(.container, edges: .top)
    }
    .sheet(item: $cleanup.preview) { plan in TrashPreviewSheet(plan: plan, scan: scan) }
    .sheet(item: $cleanup.permanentReview) { review in PermanentCleanupSheet(review: review, scan: scan) }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if section != .plan && cleanup.permanentReview == nil && (cleanup.busy || (section != .uninstall && showsMoveResult)) {
        HStack {
          if cleanup.busy {
            WorkspaceActivityIndicator()
            Text(
              ReviewLanguage.text(
                cleanup.applying ? "Çöp’e taşınıyor…" : "Seçilen klasörler doğrulanıyor…"))
            Button("Durdur") { cleanup.cancel() }
              .workspaceButton(.secondary)
          } else if let result = cleanup.outcome {
            Text(
              ReviewLanguage.format("Çöp’e taşınan: %lld öğe · %@", Int64(result.moved.count),
                ReviewLanguage.format("Tahmini kazanım: %@",
                  byteLabel(result.moved.reduce(0) { $0 + $1.expectedRecoveryBytes })))
            )
            Spacer()
            Button("Son işlem") {
              section = .plan
              showsMoveResult = false
            }
            .workspaceButton(.secondary)
            Button {
              showsMoveResult = false
            } label: {
              Image(systemName: "xmark")
            }.help("Bitti")
          }
        }.font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
      }
    }
    .onChange(of: scan.report?.id) {
      if scan.phase == .finished, let report = scan.report {
        let known = Set(report.items.map(\.id))
        selectedIDs.formIntersection(known)
      }
    }
    .onChange(of: cleanup.outcome?.id) {
      if let result = cleanup.outcome {
        selectedIDs.subtract(result.completedItems)
        showsMoveResult = section != .plan
      }
    }
    .tint(Ink.sea)
    .task { if scan.phase == .idle { scan.start() } }
    .task(id: eligibilityRequest) {
      guard eligibilityRequest != nil else { return }
      await scan.refreshMoveStates()
      if !Task.isCancelled, !scan.actions.isEmpty {
        if let report = scan.report {
          selectedIDs = Set(scan.explicitSelection(selectedIDs, in: report).map(\.id))
        }
      }
    }
    .task(id: inUseIDs) {
      let ids = inUseIDs
      guard !ids.isEmpty else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(12)) } catch { return }
        if !scan.cleanup.busy { await scan.refreshMoveStates(only: ids) }
      }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        LayerMark().frame(width: 32, height: 32)
        Text("MacPurge").font(.system(size: 19, weight: .bold)).tracking(-0.7)
      }
      .padding(.leading, 18).padding(.top, 13).padding(.bottom, 19)

      List(selection: Binding<LiveSection?>(
        get: { section }, set: { if let value = $0 { section = value } })) {
        sidebarRow("Genel bakış", symbol: "square.grid.2x2", destination: .overview)
        Section("Clean") {
          sidebarRow("Proje klasörleri", symbol: "folder", destination: .projects)
          sidebarRow("Alan planı", symbol: "scope", destination: .plan)
        }
        Section("Review") {
          sidebarRow("Depolama", symbol: "externaldrive", destination: .storage)
          sidebarRow("Uninstall Apps", symbol: "app.dashed", destination: .uninstall)
          sidebarRow("Duplicates", symbol: "doc.on.doc", destination: .duplicates)
        }
      }
      .listStyle(.sidebar)

      SettingsSidebarFooter(scan: scan, selected: section == .settings) { section = .settings }
      trashButton
        .padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 10)
    }
    .scrollContentBackground(.hidden)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func sidebarRow(_ title: LocalizedStringKey, symbol: String, destination: LiveSection) -> some View {
    SidebarLabel(title, symbol: symbol, selected: section == destination)
      .tag(destination)
  }

  private var trashButton: some View {
    let reading = CategorySize.read(.trash, in: scan.storageReport, pending: scan.pendingCategories)
    let selected = section == .trash
    return Button {
      section = .trash
    } label: {
      HStack {
        Label("Trash contents", systemImage: "trash").lineLimit(1)
        Spacer()
        if reading.bytes != nil {
          Text(reading.label).monospacedDigit().fontWeight(.semibold).fixedSize()
        }
      }
      .font(.callout)
      .padding(.horizontal, 11).padding(.vertical, 8)
      .background(.primary.opacity(selected ? 0.12 : 0.055), in: .rect(cornerRadius: 9))
      .contentShape(.rect(cornerRadius: 9))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var inUseIDs: Set<String> {
    guard eligibilityRequest != nil else { return [] }
    return Set(scan.actions.compactMap { id, action in
      if case .inUse = action.availability { id } else { nil }
    })
  }
  private var eligibilityRequest: UUID? {
    guard scan.phase == .finished,
      scenePhase == .active
    else { return nil }
    return scan.inventoryID
  }
}

private struct OverviewCleanupSection: Identifiable {
  let group: ScanGroup
  let items: [ReportItem]
  let cleanable: [ReportItem]
  let bytes: Int64
  var id: ScanGroup { group }
}

private struct LiveOverview: View {
  let scan: LiveScan
  @Binding var selected: Set<String>
  let openStorage: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let rows = scan.overviewCandidates
    let byCategory = Dictionary(grouping: rows, by: \.category)
    let groups = ScanGroup.allCases.compactMap { group -> OverviewCleanupSection? in
      guard let items = byCategory[group.rawValue] else { return nil }
      let cleanable = scan.distinctCleanups(items)
      let bytes = scan.cleanupBytes(cleanable)
      return OverviewCleanupSection(group: group, items: items, cleanable: cleanable, bytes: bytes)
    }.sorted { lhs, rhs in
      lhs.bytes == rhs.bytes ? lhs.group.rawValue < rhs.group.rawValue : lhs.bytes > rhs.bytes
    }
    let rootsByID = groups.isEmpty ? [:] : Dictionary(scan.roots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    Page(overviewLayout: true) {
      PageTitle(title: "Genel bakış") {
        SafeTrashButton(scan: scan, items: rows.filter { scan.action(for: $0).risk == .safe })
      }
    } content: {
      if let disk = scan.volume {
        let safeBytes = safeCleanupBytes(rows)
        let sizes = DiskBreakdown.sizes(in: scan.storageReport,
          pending: scan.pendingCategories, volumeDevice: scan.volumeDevice)
        let safeGroups = Dictionary(grouping: scan.safeMoves(rows), by: \.category)
        let safeByGroup = Dictionary(uniqueKeysWithValues: ScanGroup.allCases.map {
          ($0, scan.cleanupBytes(safeGroups[$0.rawValue] ?? []))
        })
        DiskBreakdownView(disk: disk,
          breakdown: DiskBreakdown(reading: disk, sizes: sizes,
            safeBytes: safeBytes, safeByGroup: safeByGroup), updating: scan.phase == .running)
      } else if scan.phase == .finished {
        Note(symbol: "internaldrive", text: "Disk kapasitesi okunamadı.")
      }
      if let report = scan.report, !rows.isEmpty {
        OverviewHighlights(scan: scan, report: report, items: Array(scan.distinctCleanups(rows).prefix(OverviewCategory.previewLimit)),
          previous: report.previous(in: scan.history), selected: $selected)
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          SectionHead(title: "Temizlenebilir alanlar")
          if !rows.isEmpty {
            ForEach(SafetyLevel.allCases, id: \.self) { level in
              Label(ReviewLanguage.text(level.rawValue), systemImage: level.symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(level.color(in: scheme))
                .fixedSize()
            }
          }
        }
        HStack {
          ScanStatus(scan: scan).frame(maxWidth: .infinity, alignment: .leading)
          let choices = rows.filter { selected.contains($0.id) && scan.listMoveState($0) == .ready }
          if !choices.isEmpty {
            Text(scan.selectionLabel(scan.distinctMoves(choices))).font(.callout.monospacedDigit())
            Button("Seçilenleri Çöp’e taşı…") {
              scan.cleanup.prepare(choices, scan: scan, explicit: true)
            }
            .workspaceButton().disabled(scan.cleanup.busy)
          }
        }
        if !groups.isEmpty {
          InventoryList(groups) { section in
            ScanGroupView(section: section, scan: scan, rootsByID: rootsByID, selected: $selected)
          }
        } else if scan.phase.awaitsMeasurements || (scan.phase == .finished
          && scan.actions.isEmpty && scan.report?.items.isEmpty == false) {
          WorkspaceSkeleton(layout: .inventory, message: "Kontrol ediliyor…", rows: 4)
        } else if scan.phase == .finished {
          Note(symbol: "checkmark.circle", text: "Şu anda Çöp’e taşınabilecek bir öğe yok.")
        }
        Button("Tüm ölçümleri Depolama’da gör", action: openStorage).buttonStyle(.link)
        if let note = scan.selectionNote { Note(symbol: "folder", text: note) }
      }
    }
  }

  private func safeCleanupBytes(_ rows: [ReportItem]) -> Int64? {
    guard scan.phase == .finished, let report = scan.report,
      report.items.allSatisfy({ scan.hiddenIDs.contains($0.id) || scan.actions[$0.id] != nil })
    else { return nil }
    return scan.cleanupBytes(scan.safeMoves(rows))
  }
}

struct WorkspaceScanControls: View {
  let scan: LiveScan

  var body: some View {
    HStack(spacing: 8) {
      if scan.phase == .running {
        scanButton("Taramayı durdur", icon: "stop.circle", labelStyle: .titleAndIcon,
          borderShape: .capsule, action: scan.cancel)
      } else {
        scanButton("Hızlı tarama", icon: "bolt", labelStyle: .iconOnly, action: scan.startQuick)
          .disabled(scan.cleanup.busy)
        scanButton("Ayrıntılı tarama", icon: "bolt.badge.clock", labelStyle: .iconOnly, action: scan.startDetailed)
          .disabled(scan.cleanup.busy)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private func scanButton(_ title: LocalizedStringKey, icon: String, labelStyle: some LabelStyle,
    borderShape: ButtonBorderShape = .circle, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: icon).labelStyle(labelStyle)
    }
    .workspaceButton(.secondary, controlSize: WorkspaceControlLayout.toolbarSize, borderShape: borderShape)
    .help(Text(title))
  }
}

struct ScanStatus: View {
  let scan: LiveScan
  var body: some View {
    if scan.phase == .running {
      switch scan.progressStage {
      case .discovering:
        progressBar("Konumlar aranıyor…")
      case .measuring(let title, let start, let total):
        let completed = min(total, max(0, scan.results.count - start))
        progressBar(
          title, detail: scan.activeRoot?.displayTitle, count: "\(completed)/\(total)",
          fraction: total > 0 ? Double(completed) / Double(total) : nil)
      case .finishing:
        progressBar("Sonuçlar hazırlanıyor…")
      }
    } else {
      HStack(spacing: 8) {
        Image(systemName: scan.phase == .finished ? "checkmark.circle" : "pause.circle")
        switch scan.phase {
        case .idle: Text("Tarama hazırlanıyor")
        case .cancelled:
          Text("Durduruldu · \(scan.results.count)/\(scan.roots.count) konum tamamlandı")
        case .finished:
          if let date = scan.measuredAt {
            Text("Son ölçüm \(date.reviewDate(date: .omitted, time: .shortened)) · \(scan.results.count) konum kontrol edildi")
          }
        case .running: EmptyView()
        }
      }.font(.callout).foregroundStyle(.secondary)
    }
  }

  private func progressBar(
    _ title: String, detail: String? = nil, count: String? = nil, fraction: Double? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 7) {
        Text(ReviewLanguage.text(title)).fontWeight(.medium)
        if let detail {
          Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
          Text(ReviewLanguage.text(detail)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 4)
        if let count {
          Text(verbatim: count).monospacedDigit().foregroundStyle(.secondary).fixedSize()
        }
      }.font(.callout)
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .tint(Ink.sea)
        .accessibilityLabel(ReviewLanguage.text(title))
    }
  }
}

extension ScanGroup {
  var symbol: String {
    switch self {
    case .xcode: "hammer"
    case .simulators: "iphone"
    case .packages: "shippingbox"
    case .projects: "folder"
    case .logs: "doc.text"
    case .runtimes: "square.stack.3d.up"
    case .models: "cpu"
    case .tools: "wrench"
    case .temp: "hourglass"
    case .docker: "shippingbox"
    case .machines: "desktopcomputer"
    case .trash: "trash"
    case .backups: "iphone.and.arrow.forward"
    case .shared: "person.2"
    case .android: "apps.iphone"
    case .appCaches: "internaldrive"
    case .apps: "app"
    case .system: "gearshape"
    case .other: "folder.badge.questionmark"
    case .snapshots: "clock.arrow.circlepath"
    case .downloads: "arrow.down.circle"
    }
  }
  var tint: Color {
    switch self {
    case .packages, .logs, .temp: Ink.gold
    case .simulators, .projects, .models, .machines: Ink.sky
    default: Ink.sea
    }
  }
  var detail: String {
    switch self {
    case .xcode: "Derleme çıktıları, arşivler ve aygıt desteği"
    case .simulators: "Cihaz başına yerel veriler ve önbellekler"
    case .packages: "Paket yöneticilerinin bilinen yerel depoları"
    case .projects: "Seçtiğin klasörlerin tamamı"
    case .logs: "Kullanıcı günlükleri ve tanılama raporları"
    case .models: "Model ağırlıkları, yerel imajlar ve yapay zekâ araçları"
    case .android: "SDK, emülatörler ve Android Studio"
    case .appCaches: "Verified caches that apps can rebuild."
    case .apps: "Uygulama desteği ve medya kitaplıkları"
    case .tools: "Editörler, eklentiler ve geliştirme ortamları"
    case .runtimes: "Cihazlardan ayrı, yüklü simülatör imajları"
    case .other: "Araç konumlarında ve seçtiğin klasörlerde 500 MiB ve üzeri alt klasörler"
    case .temp: "macOS’un geçici dosya ve önbellek klasörleri"
    case .system: "Sistem önbellekleri, destek dosyaları ve komut satırı araçları"
    default: "Yerel envanter ve ölçüm kapsamı"
    }
  }
}

private struct ScanGroupView: View {
  let section: OverviewCleanupSection
  let scan: LiveScan
  let rootsByID: [String: ScanRoot]
  @Binding var selected: Set<String>
  @State private var isExpanded = false
  @State private var showAll = false

  var body: some View {
    let group = section.group
    let items = section.items
    let cleanable = section.cleanable
    let eligible = cleanable.filter { scan.listMoveState($0) == .ready }
    let counts = Dictionary(grouping: cleanable.compactMap { scan.action(for: $0).risk }, by: { $0 }).mapValues(\.count)
    InventoryDisclosure(
      isExpanded: $isExpanded, selectable: eligible, selected: $selected, busy: scan.cleanup.busy
    ) {
      VStack(alignment: .leading, spacing: 0) {
        InventoryRows(Array(showAll ? items[...] : items.prefix(OverviewCategory.previewLimit))) { item in
          InventoryMeasuredRow(scan: scan, item: item, selected: $selected,
            root: rootsByID[item.category + "|" + item.path], amount: byteLabel(scan.action(for: item).bytes))
        }
        if items.count > OverviewCategory.previewLimit {
          Button(showAll ? "Daha az göster" : "Tümünü göster") { showAll.toggle() }
            .buttonStyle(.link).padding(InventoryLayout.verticalPadding)
        }
      }
    } label: {
      InventoryGroupHeader(title: ReviewLanguage.text(group.titleKey), symbol: group.symbol,
        tint: group.tint, amount: byteLabel(section.bytes)) {
        ForEach(SafetyLevel.allCases, id: \.self) { level in
          if let count = counts[level] { SafetyBadge(level: level, count: count) }
        }
      }.help(ReviewLanguage.text(group.detail))
    } accessory: {
      CategoryMoveButton(scan: scan, group: group, items: items, eligible: eligible.count)
    }
  }
}

extension SafetyLevel {
  var symbol: String { self == .safe ? "checkmark.shield" : "eye" }
  func color(in scheme: ColorScheme) -> Color {
    switch self {
    case .safe: scheme == .dark ? .mint : Color(red: 0.08, green: 0.39, blue: 0.27)
    case .review: scheme == .dark ? .orange : Color(red: 0.56, green: 0.29, blue: 0.04)
    }
  }
}

struct SafetyBadge: View {
  let level: SafetyLevel
  var count: Int? = nil
  var titleKey: String? = nil
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let color = level.color(in: scheme)
    let title =
      count.map { number in
        let format = ReviewLanguage.text(
          level == .safe ? "%lld güvenli öğe" : "%lld öğe incelenmeli")
        return String(format: format, Int64(number))
      } ?? ReviewLanguage.text(titleKey ?? level.rawValue)
    HStack(spacing: 3) {
      Image(systemName: level.symbol)
      if let count {
        Text(count.formatted()).monospacedDigit()
      } else {
        Text(title)
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 7).padding(.vertical, 2)
    .background(color.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .help(title)
  }
}
