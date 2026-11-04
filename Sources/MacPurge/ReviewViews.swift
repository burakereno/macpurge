import AppKit
import Charts
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

struct StorageRoute {
  var showsItems = false
  var category: ScanGroup?
  var filter: SafetyFilter = .all

  static func items(in category: ScanGroup?, filter: SafetyFilter = .all) -> Self {
    Self(showsItems: true, category: category, filter: filter)
  }
}

struct StorageBrowser: View {
  let scan: LiveScan
  @Binding var selected: Set<String>
  @Binding var route: StorageRoute
  let openPlan: () -> Void
  @State private var text = ""
  private var category: ScanGroup? { route.category }
  private var filter: SafetyFilter { route.filter }
  private var listing: Bool { route.showsItems || !text.isEmpty }
  @State private var focus: String?
  @State private var sorting: [KeyPathComparator<ReportItem>] = [
    .init(\.numericSize, order: .reverse), .init(\.id)
  ]
  @State private var inspecting = false
  @State private var pendingInspectorMove: ReportItem?
  private var report: ScanReport? { scan.storageReport }
  private var previous: ScanReport? {
    guard scan.phase == .finished, let report else { return nil }
    return report.previous(in: scan.history)
  }

  private func matchesFilters(_ item: ReportItem) -> Bool {
    let risk = scan.filterRisk(for: item)?.rawValue
    guard !scan.hiddenIDs.contains(item.id), category == nil || item.category == category?.rawValue,
      filter == .all || (filter == .unavailable ? scan.listMoveState(item) != .ready : risk == filter.rawValue)
    else { return false }
    return text.isEmpty
      || [
        item.name, item.actionTitle, item.category, item.path,
        ScanGroup(rawValue: item.category).map { ReviewLanguage.text($0.titleKey) } ?? "",
      ].contains { $0.localizedCaseInsensitiveContains(text) }
  }

  private var visible: [ReportItem] {
    let rows = (report?.items ?? []).filter(matchesFilters)
    guard category != nil else { return rows.sorted(using: sorting) }
    return rows.sorted { lhs, rhs in
      lhs.numericSize == rhs.numericSize ? lhs.id < rhs.id : lhs.numericSize > rhs.numericSize
    }
  }

  private var outsideFilter: Int {
    // A row that hasn't been measured in a progressive scan isn't hidden by a filter.
    (report?.items ?? []).filter { selected.contains($0.id) && !matchesFilters($0) }.count
  }

  var body: some View {
    GeometryReader { viewport in
      let rows = listing ? visible : []
      VStack(alignment: .leading, spacing: 12) {
        PageTitle(
          kicker: "Çalışma alanı", title: "Depolama",
          subtitle: category == .temp
            ? "Dosyalar son değişiklik zamanına göre ayrılır. Eksik ölçümler alt sınır olarak gösterilir."
            : listing
              ? "Ölçülen öğeleri incele ve alan hedefin için adayları karşılaştır."
              : "Çubuklar en büyük kategoriye göre ölçeklenir. Renkler ölçülen alanın dağılımını gösterir."
        )
        HStack {
          if listing {
            Text(ReviewLanguage.text(category?.titleKey ?? "Tüm öğeler")).font(.headline)
          } else {
            Text("Kategoriler").font(.headline)
          }
          Spacer()
          if scan.phase != .running && (report?.extended == false || scan.phase == .cancelled) {
            Button("Ayrıntılı tarama", action: scan.startDetailed)
          }
          if category == .other {
            Button("Taranacak klasörü seç…", action: scan.chooseLargeFolders)
          }
          if listing {
            SafeTrashButton(
              scan: scan, group: category,
              items: rows.filter { $0.safety == SafetyLevel.safe.rawValue })
          }
          if !listing {
            Button("Tüm öğeler") { route = .items(in: nil) }
          }
        }
        if scan.phase == .running { ScanStatus(scan: scan) }
        if listing { filters }
        GeometryReader { slot in
          if listing {
            storageTable(rows).frame(width: slot.size.width, height: slot.size.height)
          } else {
            StorageCategoryIndex(
              scan: scan, report: report,
              pending: scan.phase == .running ? scan.pendingCategories : [],
              changes: report?.makeDeltas(since: previous) ?? [:]
            ) { group in
              route = .items(in: group)
              focus = nil
            }.frame(width: slot.size.width, height: slot.size.height)
          }
        }
        if listing, !selected.isEmpty, let report {
          let choices = scan.explicitSelection(selected, in: report)
          Button {
            scan.cleanup.prepare(choices, scan: scan, explicit: true)
          } label: {
            Label("Seçilenleri Çöp’e taşı…", systemImage: "trash")
          }
          .disabled(scan.phase != .finished || choices.isEmpty || scan.cleanup.busy)
        }
        ViewThatFits(in: .horizontal) {
          HStack {
            footerSummary(rows.count).fixedSize(horizontal: true, vertical: false)
            Spacer()
            footerActions(rows).fixedSize()
          }
          VStack(alignment: .leading, spacing: 6) {
            footerSummary(rows.count)
            footerActions(rows).frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
      .padding(22)
      .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
    }
    .searchable(text: $text, prompt: "Öğe, kategori veya konum ara")
    .toolbar {
      if listing {
        ToolbarItem(placement: .navigation) {
          Button {
            route = StorageRoute()
            text = ""
            focus = nil
          } label: {
            Label("Kategoriler", systemImage: "chevron.left")
          }
          .labelStyle(.iconOnly)
          .help(ReviewLanguage.text("Kategoriler"))
          .keyboardShortcut("[", modifiers: .command)
        }
      }
    }
    .sheet(
      isPresented: $inspecting,
      onDismiss: {
        if let item = pendingInspectorMove {
          pendingInspectorMove = nil
          if scan.action(for: item).permanentOperation != nil {
            scan.cleanup.reviewPermanentCleanup(item, scan: scan)
          } else {
            scan.cleanup.prepare([item], scan: scan, explicit: true)
          }
        }
      }
    ) {
      if let item = report?.items.first(where: { $0.id == focus }) {
        ItemInspector(scan: scan, item: item) {
          pendingInspectorMove = item
          inspecting = false
        }
      }
    }
  }

  @ViewBuilder private func footerSummary(_ count: Int) -> some View {
    if listing {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(count) öğe · \(selected.count) seçim")
        if !selected.isEmpty && (category != nil || filter != .all || !text.isEmpty) {
          Text(ReviewLanguage.format("%lld seçim filtre dışında", Int64(outsideFilter)))
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

  private func footerActions(_ rows: [ReportItem]) -> some View {
    HStack {
      if listing {
        let movable = Set(scan.distinctMoves(rows).map(\.id))
        Button("Taşınabilirleri seç") { selected.formUnion(movable) }
          .disabled(movable.isSubset(of: selected) || scan.phase != .finished)
        Button("Ayrıntılar") { inspecting = true }.disabled(!rows.contains { $0.id == focus })
      }
      Button("Alan planını aç", action: openPlan).disabled(scan.phase == .running)
    }
  }

  private var filters: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        riskPicker.fixedSize()
        categoryPicker
      }
      VStack(alignment: .leading, spacing: 6) {
        riskPicker
        categoryPicker
      }
    }
  }

  private var riskPicker: some View {
    Picker("Risk", selection: $route.filter) {
      ForEach(SafetyFilter.allCases, id: \.self) { Text(ReviewLanguage.text($0.rawValue)) }
    }.labelsHidden().pickerStyle(.segmented)
  }

  private var categoryPicker: some View {
    Picker("Kategori", selection: $route.category) {
      Text("Tüm kategoriler").tag(nil as ScanGroup?)
      ForEach(ScanGroup.allCases, id: \.self) {
        Text(ReviewLanguage.text($0.titleKey)).tag(Optional($0))
      }
    }.labelsHidden().frame(idealWidth: 180, maxWidth: 180)
  }

  private func itemTable(_ rows: [ReportItem], changes: [String: Int64]) -> some View {
    Table(rows, selection: $focus, sortOrder: $sorting) {
      TableColumn("Öğe", value: \.actionTitle) { row in itemName(row) }.width(min: 130, ideal: 215)
      TableColumn("Etiket") { row in
        ActionBadge(action: scan.action(for: row), item: row)
      }.width(min: 65, ideal: 80, max: 120)
      TableColumn("Boyut", value: \.numericSize) { row in sizeValue(row.bytes) }
        .width(min: 64, ideal: 83, max: 118).alignment(.trailing)
      TableColumn("Fark") { row in
        if let delta = changes[row.id] { SizeChange(bytes: delta) }
      }.width(min: 44, ideal: 68, max: 84).alignment(.trailing)
      TableColumn("Değişiklik", value: \.sortDate) { row in modifiedDate(row) }
        .width(min: 68, ideal: 90, max: 116)
      TableColumn("İşlem") { row in ItemTrashButton(scan: scan, item: row) }
        .width(54).alignment(.center)
    }
  }

  private func itemName(_ row: ReportItem) -> some View {
    HStack(spacing: 7) {
      Group {
        if scan.listMoveState(row) == .ready {
          Toggle(row.actionTitle, isOn: Binding(
            get: { selected.contains(row.id) },
            set: { on in
              if on { selected.insert(row.id) } else { selected.remove(row.id) }
            })
          ).toggleStyle(.checkbox).labelsHidden().controlSize(.small).disabled(scan.cleanup.busy)
        } else { Color.clear.accessibilityHidden(true) }
      }.frame(width: InventoryLayout.selectionWidth, height: 18)
      Text(row.actionTitle).lineLimit(1).truncationMode(.middle).help(row.path)
    }.frame(minHeight: 22)
  }

  private func categoryTable(_ rows: [ReportItem], changes: [String: Int64]) -> some View {
    let showsAge = category == .temp
    let changeTitle: LocalizedStringKey = showsAge ? "Son 72 saat" : "Fark"
    let dateTitle: LocalizedStringKey = showsAge ? "72 saatten eski" : "Değişiklik"
    return Table(rows, selection: $focus) {
      TableColumn("Öğe") { row in itemName(row) }.width(min: 130, ideal: 215)
      TableColumn("Etiket") { row in
        ActionBadge(action: scan.action(for: row), item: row)
      }.width(min: 65, ideal: 80, max: 120)
      TableColumn("Boyut") { row in sizeValue(row.bytes, partial: showsAge && !row.complete) }
        .width(min: 64, ideal: 83, max: 118).alignment(.trailing)
      TableColumn(changeTitle) { row in
        if showsAge { sizeValue(row.age?.recent, partial: !row.complete) }
        else if let delta = changes[row.id] { SizeChange(bytes: delta) }
      }.width(min: showsAge ? 68 : 44, ideal: showsAge ? 96 : 68, max: showsAge ? 124 : 84)
        .alignment(.trailing)
      TableColumn(dateTitle) { row in
        if showsAge { sizeValue(row.age?.older, partial: !row.complete) }
        else { modifiedDate(row) }
      }.width(min: showsAge ? 78 : 68, ideal: showsAge ? 104 : 90, max: showsAge ? 130 : 116)
      TableColumn("İşlem") { row in ItemTrashButton(scan: scan, item: row) }
        .width(54).alignment(.center)
    }
  }

  private func modifiedDate(_ row: ReportItem) -> some View {
    Text(row.modified.map { $0.reviewDate(date: .abbreviated, time: .omitted) } ?? "—")
      .font(.caption).foregroundStyle(.secondary)
  }

  private func sizeValue(_ bytes: Int64?, partial: Bool = false) -> some View {
    Text(bytes.map { (partial ? "≥ " : "") + byteLabel($0) } ?? "—")
      .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
  }

  private func storageTable(_ rows: [ReportItem]) -> some View {
    let changes = Dictionary(
      uniqueKeysWithValues: (report?.growth(since: previous) ?? []).map { ($0.0.id, $0.1) })
    return Group {
      if category != nil { categoryTable(rows, changes: changes) }
      else { itemTable(rows, changes: changes) }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .contextMenu(forSelectionType: String.self) { ids in
      Button("Ayrıntıları göster") {
        if let id = ids.first { focus = id; inspecting = true }
      }
      Button("Finder’da aç") {
        if let id = ids.first, let row = report?.items.first(where: { $0.id == id }) {
          InventoryLocation.open(URL(fileURLWithPath: row.path))
        }
      }.disabled(ids.count != 1)
      Button("Önerilerden gizle") {
        if let id = ids.first, let row = report?.items.first(where: { $0.id == id }) {
          scan.hide(row)
          selected.remove(id)
        }
      }
    } primaryAction: { ids in
      if let id = ids.first { focus = id; inspecting = true }
    }
    .overlay {
      if rows.isEmpty, let category, CategorySize.read(category, in: report) == .outsideScope {
        ContentUnavailableView {
          Label("Hızlı tarama dışında", systemImage: category.symbol)
        } actions: {
          Button("Ayrıntılı tarama", action: scan.startDetailed).disabled(scan.phase == .running)
        }
      } else if rows.isEmpty {
        ContentUnavailableView(
          "Sonuç yok", systemImage: "magnifyingglass",
          description: Text("Filtreyi değiştir veya taramanın tamamlanmasını bekle."))
      }
    }
  }

}

extension ReportItem {
  fileprivate var numericSize: Int64 { bytes ?? -1 }
  fileprivate var sortDate: Date { modified ?? .distantPast }
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
        }.help("Runtime’ları Xcode → Settings → Components bölümünde yönetebilirsin.")
      }
      if let openError { Text(openError).font(.caption) }
    }
  }
}

struct ItemInspector: View {
  let scan: LiveScan
  let item: ReportItem
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
      LabeledContent(
        "Kaynak",
        value: ReviewLanguage.text(item.estimated
          ? "Aracın bildirdiği boyut"
          : (item.status == "partial" ? "Kısmi disk ölçümü" : "Dosya sistemi")))
      ScrollView {
        Surface {
          InventoryItemDetails(item: item).padding(.horizontal, SurfaceCorners.rowInset)
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
        }
        ItemTrashButton(scan: scan, item: item, showActionTitle: true, beforePreview: prepare)
        Spacer()
        Button("Bitti") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(minWidth: 450, idealWidth: 540)
  }
}

struct SpacePreview: View {
  let scan: LiveScan
  @Binding var selected: Set<String>
  @State private var target = 20
  var body: some View {
    Page {
      PageTitle(
        kicker: "Çalışma alanı", title: "Alan planı",
        subtitle: "Güvenli olarak ölçülen adaylardan bir hedef belirle ve beklenen etkileri incele."
      )
      if let report = scan.report {
        let regrowth = scan.historyEnabled ? scan.regrownFolders ?? [] : []
        let selectedRows = scan.explicitSelection(selected, in: report)
        let choices = scan.distinctMoves(selectedRows)
        let bytes = scan.cleanupBytes(choices)
        let goal = Int64(target) * 1_000_000_000
        Surface {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Picker("Hedef", selection: $target) {
                ForEach([1, 5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
              }.frame(maxWidth: 210)
              Spacer()
              Button("Adayları öner") {
                selected = Set(
                  report.plan(
                    target: goal, excluding: scan.hiddenIDs, moveStates: scan.moveStates,
                    regrowth: regrowth, actionBytes: scan.actions.mapValues(\.bytes)
                  )
                  .map(\.id))
              }.disabled(scan.phase != .finished || !scan.actions.values.contains { $0.risk == .safe })
                .help(
                  "72 saat içinde eski boyutunun en az yarısına dönen klasörler son sırada önerilir. Yeterli geçmiş yoksa en büyük güvenli öğeler önce gelir."
                )
            }
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
      } else {
        ContentUnavailableView("Ölçüm bekleniyor", systemImage: "scope")
      }
    }
  }
}

struct ScanActivity: View {
  let scan: LiveScan
  @Binding var selected: Set<String>
  @State private var confirming = false
  var body: some View {
    Page {
      PageTitle(
        kicker: "Çalışma alanı", title: "Etkinlik",
        subtitle: "Son tamamlanan taramaları ve ortak öğelerdeki değişimi karşılaştır.")
      Toggle(
        "Ölçüm geçmişini bu Mac’te tut",
        isOn: Binding(
          get: { scan.historyEnabled },
          set: { enabled in
            if enabled { Task { await scan.setHistory(true) } } else { confirming = true }
          }))
      if let message = scan.historyError { Note(symbol: "exclamationmark.triangle", text: message) }
      if let saved = scan.history.first {
        let current = scan.inventoryID == saved.id ? (scan.report ?? saved) : saved
        let prior = current.previous(in: scan.history)
        let growth = current.growth(since: prior).filter { $0.1 > 0 }
        if scan.history.compactMap(\.free).count > 1 {
          SectionHead(title: "Boş alan geçmişi")
          Chart(scan.history.reversed()) { point in
            if let free = point.free {
              LineMark(x: .value("Tarih", point.date), y: .value("GB", Double(free) / 1e9))
                .foregroundStyle(Ink.sea)
              PointMark(x: .value("Tarih", point.date), y: .value("GB", Double(free) / 1e9))
                .foregroundStyle(Ink.sea)
            }
          }.chartYAxisLabel("GB").frame(height: 145)
        }
        WeeklyGrowthView(scan: scan, report: current, selected: $selected)
        let unusual = current.unusualGroups(previous: scan.history)
        if !unusual.isEmpty {
          SectionHead(title: "Olağandışı artışlar")
          InventoryList(unusual, id: \.0) { group, _, delta in
            let category = ScanGroup(rawValue: group)
            InventoryReadout(title: ReviewLanguage.text(category?.titleKey ?? group),
              amount: "+" + byteLabel(delta), symbol: category?.symbol ?? "chart.bar")
          }
        }
        SectionHead(title: "Yeniden büyüyen klasörler")
        if let folders = scan.regrownFolders {
          if folders.isEmpty {
            Text("Son taramada, Çöp’e taşındıktan sonra yeniden yer kaplayan klasör bulunmadı.")
              .font(.callout).foregroundStyle(.secondary)
          }
          InventoryList(folders) { folder in
            let caption = ReviewLanguage.text("Çöp’e taşınan") + " · " + byteLabel(folder.move.receipt.bytes)
              + " · " + folder.move.receipt.date.reviewDate(date: .abbreviated, time: .shortened)
              + " · " + ReviewLanguage.text("Yeniden ölçülen") + " · "
              + folder.measuredAt.reviewDate(date: .abbreviated, time: .shortened)
            if scan.report?.id == current.id,
              let item = current.items.first(where: { $0.id == folder.move.itemID }) {
              InventoryMeasuredRow(scan: scan, item: item, selected: $selected,
                amount: byteLabel(folder.bytes), caption: caption, onlyPath: folder.move.receipt.original)
            } else {
              InventoryReadout(title: ReviewLanguage.text(folder.move.name), amount: byteLabel(folder.bytes),
                subtitle: caption, location: folder.move.receipt.original)
            }
          }
        } else {
          Text("Temizlik geçmişi tamamlanan taramayla karşılaştırılacak.").font(.callout)
            .foregroundStyle(.secondary)
        }
        SectionHead(title: "Büyüyen öğeler")
        if prior == nil {
          Note(
            symbol: "clock",
            text: "Değişim için aynı kapsamda ikinci bir tamamlanmış tarama gerekiyor.")
        } else if growth.isEmpty {
          Note(symbol: "checkmark.circle", text: "Karşılaştırılabilen öğelerde büyüme görülmedi.")
        } else {
          InventoryList(Array(growth.prefix(8)), id: \.0.id) { row, change in
            if scan.report?.id == current.id {
              InventoryMeasuredRow(scan: scan, item: row, selected: $selected,
                amount: row.bytes.map(byteLabel), delta: change)
            } else {
              InventoryReadout(title: row.actionTitle, amount: "+" + byteLabel(change),
                subtitle: row.shortPath)
            }
          }
        }
        let recentScans = Array(scan.history.prefix(5))
        SectionHead(title: "Son taramalar", note: "\(recentScans.count)")
        InventoryList(recentScans) { saved in
          InventoryReadout(title: saved.date.reviewDate(date: .abbreviated, time: .shortened),
            amount: saved.free.map(byteLabel) ?? "—", symbol: "clock.arrow.circlepath",
            subtitle: ReviewLanguage.format("%@ · %lld öğe", ReviewLanguage.text(saved.extended
              ? "Ayrıntılı tarama" : "Hızlı tarama"), Int64(saved.items.count)))
        }
      } else {
        ContentUnavailableView(
          scan.historyEnabled ? "Henüz geçmiş yok" : "Geçmiş kapalı", systemImage: "clock")
      }
    }.alert("Geçmiş kapatılsın mı?", isPresented: $confirming) {
      Button("Vazgeç", role: .cancel) {}
      Button("Geçmişi temizle", role: .destructive) { Task { await scan.setHistory(false) } }
    } message: {
      Text("MacPurge’ün yerel tarama kayıtları temizlenir.")
    }
  }
}
