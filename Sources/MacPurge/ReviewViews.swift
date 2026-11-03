import AppKit
import Charts
import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct OverviewHighlights: View {
  let report: ScanReport
  let previous: ScanReport?
  let openStorage: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        SectionHead(title: "En çok yer tutanlar")
        Button("Tümünü gör", action: openStorage).buttonStyle(.link)
      }
      Text("Son tamamlanan tarama · \(report.date.formatted(date:.abbreviated,time:.shortened))")
        .font(.caption).foregroundStyle(.secondary)
      let largest = Array(report.items.filter { ($0.bytes ?? 0) > 0 }.prefix(3))
      let growth = Dictionary(
        uniqueKeysWithValues: report.growth(since: previous).map { ($0.0.id, $0.1) })
      if largest.isEmpty {
        Text("Bu kapsamda ölçülebilen veri yok.").foregroundStyle(.secondary)
      } else {
        Surface {
          VStack(spacing: 0) {
            ForEach(largest) { item in
              HStack {
                Image(systemName: ScanGroup(rawValue: item.category)?.symbol ?? "folder")
                  .foregroundStyle(Ink.sea)
                Text(item.name).lineLimit(1)
                Spacer()
                if let delta = growth[item.id] {
                  Text((delta > 0 ? "+" : "−") + byteLabel(abs(delta))).font(.caption)
                    .foregroundStyle(delta > 0 ? Ink.gold : Ink.sea)
                }
                Text(byteLabel(item.bytes ?? 0)).monospacedDigit()
              }.padding(.horizontal, 15).padding(.vertical, 9)
              if item.id != largest.last?.id { Divider() }
            }
          }
        }
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
  case unavailable = "Ölçülemedi"
}

struct StorageBrowser: View {
  let scan: LiveScan
  @Binding var selected: Set<String>
  let openPlan: () -> Void
  @State private var text = ""
  @State private var filter: SafetyFilter = .all
  @State private var category: ScanGroup?
  @State private var showsItems = false
  private var listing: Bool { showsItems || !text.isEmpty }
  @State private var focus: String?
  @State private var sorting: [KeyPathComparator<ReportItem>] = [
    .init(\.numericSize, order: .reverse)
  ]
  @State private var ageSorting: [KeyPathComparator<ReportItem>] = [
    .init(\.numericSize, order: .reverse)
  ]
  @State private var inspecting = false
  private var report: ScanReport? {
    scan.phase == .running && scan.detailed ? scan.storagePreview : scan.report
  }
  private var previous: ScanReport? {
    guard scan.phase == .finished, let report else { return nil }
    return report.previous(in: scan.history)
  }

  private func matchesFilters(_ item: ReportItem) -> Bool {
    guard !scan.hiddenIDs.contains(item.id), category == nil || item.category == category?.rawValue,
      filter == .all || (filter == .unavailable ? !item.complete : item.safety == filter.rawValue)
    else { return false }
    return text.isEmpty
      || [
        item.name, item.category, item.path,
        ScanGroup(rawValue: item.category).map { ReviewLanguage.text($0.titleKey) } ?? "",
      ].contains { $0.localizedCaseInsensitiveContains(text) }
  }

  private var visible: [ReportItem] {
    (report?.items ?? []).filter(matchesFilters).sorted(
      using: category == .temp ? ageSorting : sorting)
  }

  private var outsideFilter: Int {
    // A row that hasn't been measured in a progressive scan isn't hidden by a filter.
    (scan.report?.items ?? []).filter { selected.contains($0.id) && !matchesFilters($0) }.count
  }

  var body: some View {
    GeometryReader { viewport in
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
            Button {
              showsItems = false
              category = nil
              text = ""
              filter = .all
              focus = nil
            } label: {
              Label("Kategoriler", systemImage: "chevron.left")
            }
          } else {
            Text("Kategoriler").font(.headline)
          }
          Spacer()
          if scan.phase == .running {
            ProgressView().controlSize(.small)
            Text("Tarama sürüyor…").font(.caption).foregroundStyle(.secondary)
          } else if report?.extended == false || scan.phase == .cancelled {
            Button("Ayrıntılı tarama", action: scan.startDetailed)
          }
          if category == .other {
            Button("Taranacak klasörü seç…", action: scan.chooseLargeFolders)
          }
          if !listing {
            Button("Tüm öğeler") { showsItems = true }
          }
        }
        if listing { filters }
        GeometryReader { slot in
          if listing {
            storageTable.frame(width: slot.size.width, height: slot.size.height)
          } else {
            StorageCategoryIndex(
              report: report, pending: scan.phase == .running ? scan.pendingCategories : [],
              changes: report?.makeDeltas(since: previous) ?? [:]
            ) { group in
              category = group
              showsItems = true
              focus = nil
            }.frame(width: slot.size.width, height: slot.size.height)
          }
        }
        HStack {
          if listing {
            VStack(alignment: .leading, spacing: 2) {
              Text("\(visible.count) öğe · \(selected.count) seçim")
              if !selected.isEmpty && (category != nil || filter != .all || !text.isEmpty) {
                Text(
                  String(
                    format: ReviewLanguage.text("%lld seçim filtre dışında"), Int64(outsideFilter)))
              }
            }.font(.caption).foregroundStyle(.secondary)
          } else if let report {
            Text(ReviewLanguage.text(report.extended ? "Ayrıntılı tarama" : "Hızlı tarama"))
              .font(.caption.weight(.semibold))
            Text(report.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(
              .secondary)
          }
          Spacer()
          if listing {
            let movable = Set(visible.filter { scan.moveStates[$0.id] == .ready }.map(\.id))
            Button("Taşınabilirleri seç") { selected.formUnion(movable) }
              .disabled(movable.isSubset(of: selected) || scan.phase != .finished)
            Button("Ayrıntılar") { inspecting = true }.disabled(
              !visible.contains { $0.id == focus })
          }
          Button("Alan planını aç", action: openPlan).disabled(scan.phase == .running)
        }
      }
      .padding(22)
      .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
    }
    .searchable(text: $text, prompt: "Öğe, kategori veya konum ara")
    .sheet(isPresented: $inspecting) {
      if let item = report?.items.first(where: { $0.id == focus }) {
        ItemInspector(item: item, moveState: scan.moveStates[item.id])
      }
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
    Picker("Risk", selection: $filter) {
      ForEach(SafetyFilter.allCases, id: \.self) { Text(ReviewLanguage.text($0.rawValue)) }
    }.labelsHidden().pickerStyle(.segmented)
  }

  private var categoryPicker: some View {
    Picker("Kategori", selection: $category) {
      Text("Tüm kategoriler").tag(nil as ScanGroup?)
      ForEach(ScanGroup.allCases, id: \.self) {
        Text(ReviewLanguage.text($0.titleKey)).tag(Optional($0))
      }
    }.labelsHidden().frame(idealWidth: 180, maxWidth: 180)
  }

  private var itemTable: some View {
    let changes = Dictionary(
      uniqueKeysWithValues: (report?.growth(since: previous) ?? []).map { ($0.0.id, $0.1) })
    return Table(visible, selection: $focus, sortOrder: $sorting) {
      TableColumn("Öğe", value: \.name) { row in Text(row.name).lineLimit(1) }.width(
        min: 130, ideal: 215)
      TableColumn("Etiket") { row in
        if let label = row.safety, let level = SafetyLevel(rawValue: label) {
          SafetyBadge(level: level)
        } else {
          Text("—").foregroundStyle(.secondary)
        }
      }.width(min: 65, ideal: 80, max: 120)
      TableColumn("Boyut", value: \.numericSize) { row in
        Text(row.bytes.map(byteLabel) ?? "—").monospacedDigit().frame(
          maxWidth: .infinity, alignment: .trailing)
      }.width(min: 64, ideal: 83, max: 118)
      TableColumn("Fark") { row in
        if let delta = changes[row.id] { SizeChange(bytes: delta) }
      }.width(min: 44, ideal: 68, max: 84)
      TableColumn("Değişiklik", value: \.sortDate) { row in
        Text(row.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").font(
          .caption
        ).foregroundStyle(.secondary)
      }.width(min: 68, ideal: 90, max: 116)
      TableColumn("Plan") { row in
        switch scan.moveStates[row.id] {
        case .ready:
          Toggle(
            "Plana ekle: \(row.name)",
            isOn: Binding(
              get: { selected.contains(row.id) },
              set: { value in
                if value { selected.insert(row.id) } else { selected.remove(row.id) }
              })
          ).toggleStyle(.checkbox).labelsHidden().disabled(scan.phase == .running)
        case .blocked(let reason):
          Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(reason)
        case nil:
          Text(
            ReviewLanguage.text(scan.phase == .finished ? "Kontrol ediliyor…" : "Ölçüm bekleniyor")
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }.width(min: 100, ideal: 148, max: 210)
    }
  }

  private var ageTable: some View {
    Table(visible, selection: $focus, sortOrder: $ageSorting) {
      TableColumn("Öğe", value: \.name) { row in Text(row.name).lineLimit(1) }
      TableColumn("Etiket") { row in
        if let label = row.safety, let level = SafetyLevel(rawValue: label) {
          SafetyBadge(level: level)
        } else {
          Text("—").foregroundStyle(.secondary)
        }
      }.width(min: 65, ideal: 80, max: 105)
      TableColumn("Boyut", value: \.numericSize) { row in ageValue(row.bytes, row) }
        .width(min: 64, ideal: 85, max: 112)
      TableColumn("Son 72 saat", value: \.recentSize) { row in ageValue(row.age?.recent, row) }
        .width(min: 68, ideal: 96, max: 124)
      TableColumn("72 saatten eski", value: \.olderSize) { row in ageValue(row.age?.older, row) }
        .width(min: 78, ideal: 104, max: 130)
    }
  }

  private func ageValue(_ bytes: Int64?, _ row: ReportItem) -> some View {
    Text(bytes.map { (row.complete ? "" : "≥ ") + byteLabel($0) } ?? "—")
      .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var storageTable: some View {
    Group {
      if category == .temp { ageTable } else { itemTable }
    }
    .contextMenu(forSelectionType: String.self) { ids in
      Button("Ayrıntıları göster") {
        if let id = ids.first {
          focus = id
          inspecting = true
        }
      }
      Button("Önerilerden gizle") {
        if let id = ids.first, let row = report?.items.first(where: { $0.id == id }) {
          scan.hide(row)
          selected.remove(id)
        }
      }
    } primaryAction: { ids in
      if let id = ids.first {
        focus = id
        inspecting = true
      }
    }
    .overlay {
      if visible.isEmpty, let category, CategorySize.read(category, in: report) == .outsideScope {
        ContentUnavailableView {
          Label("Hızlı tarama dışında", systemImage: category.symbol)
        } actions: {
          Button("Ayrıntılı tarama", action: scan.startDetailed).disabled(scan.phase == .running)
        }
      } else if visible.isEmpty {
        ContentUnavailableView(
          "Sonuç yok", systemImage: "magnifyingglass",
          description: Text("Filtreyi değiştir veya taramanın tamamlanmasını bekle."))
      }
    }
  }
}

extension ReportItem {
  fileprivate var numericSize: Int64 { bytes ?? -1 }
  fileprivate var recentSize: Int64 { age?.recent ?? -1 }
  fileprivate var olderSize: Int64 { age?.older ?? -1 }
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
    VStack(alignment: .leading, spacing: 4) {
      ForEach(usage.devices, id: \.id) { device in
        HStack {
          Text(device.name)
          Spacer()
          Text(String(device.id.uuidString.prefix(8))).monospaced().foregroundStyle(.secondary)
        }.font(.callout)
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent(
        "Son kullanım",
        value: usage.lastUsed?.formatted(date: .abbreviated, time: .shortened)
          ?? ReviewLanguage.text("Bildirilmedi"))
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
  let item: ReportItem
  let moveState: MoveAvailability?
  @Environment(\.dismiss) private var dismiss
  @State private var openError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      SectionHead(
        title: item.name, note: ScanGroup(rawValue: item.category)?.titleKey ?? item.category)
      if let label = item.safety, let level = SafetyLevel(rawValue: label) {
        SafetyBadge(level: level)
      }
      Text(ReviewLanguage.text(item.reason)).fixedSize(horizontal: false, vertical: true)
      if case .blocked(let reason) = moveState { LabeledContent("Plan", value: reason) }
      if let age = item.age { FileAgeView(age: age, partial: !item.complete) }
      if let usage = item.runtimeUsage {
        RuntimeDetails(usage: usage, compact: true)
      }
      if let workspace = item.workspace {
        LabeledContent("Xcode projesi", value: workspace).textSelection(.enabled)
      }
      LabeledContent("Ölçüm", value: item.bytes.map(byteLabel) ?? "Bilinmiyor")
      LabeledContent(
        "Kaynak",
        value: item.estimated
          ? "Aracın bildirdiği boyut"
          : (item.status == "partial" ? "Kısmi disk ölçümü" : "Dosya sistemi"))
      if let date = item.modified {
        LabeledContent(
          "Son dosya değişikliği", value: date.formatted(date: .abbreviated, time: .shortened))
      }
      Text(item.shortPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      if !item.parts.isEmpty {
        Divider()
        ForEach(item.parts.sorted { $0.value > $1.value }, id: \.key) { name, bytes in
          LabeledContent(name, value: byteLabel(bytes)).font(.callout)
        }
      }
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
        let choices = report.items.filter {
          selected.contains($0.id) && !scan.hiddenIDs.contains($0.id)
            && scan.moveStates[$0.id] == .ready
        }
        let bytes = choices.reduce(Int64(0)) { $0 + $1.eligibleBytes }
        let goal = Int64(target) * 1_000_000_000
        Surface {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Picker("Hedef", selection: $target) {
                ForEach([1, 5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
              }.frame(maxWidth: 210)
              Spacer()
              Button("Adayları öner") {
                let blocked = report.items.filter { scan.moveStates[$0.id] != .ready }.map(\.id)
                selected = Set(
                  report.plan(target: goal, excluding: scan.hiddenIDs.union(blocked)).map(\.id))
              }.disabled(!scan.moveStates.values.contains(.ready))
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
        ForEach(choices) { row in
          Surface {
            HStack {
              VStack(alignment: .leading) {
                Text(row.name).font(.headline)
                Text(ReviewLanguage.text(row.reason)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(byteLabel(row.eligibleBytes))
              Button {
                selected.remove(row.id)
              } label: {
                Image(systemName: "minus.circle")
              }.help("Plandan çıkar")
            }.padding(12)
          }
        }
        CleanupControls(scan: scan, choices: choices, reportID: report.id, selected: $selected)
      } else {
        ContentUnavailableView("Ölçüm bekleniyor", systemImage: "scope")
      }
    }
  }
}

struct ScanActivity: View {
  let scan: LiveScan
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
      if let current = scan.history.first {
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
        WeeklyGrowthView(report: current)
        let unusual = current.unusualGroups(previous: scan.history)
        if !unusual.isEmpty {
          SectionHead(title: "Olağandışı artışlar")
          ForEach(unusual, id: \.0) { group, _, delta in
            LabeledContent(group, value: "+" + byteLabel(delta))
          }
        }
        SectionHead(title: "Yeniden büyüyen klasörler")
        if let folders = scan.regrownFolders {
          if folders.isEmpty {
            Text("Son taramada, Çöp’e taşındıktan sonra yeniden yer kaplayan klasör bulunmadı.")
              .font(.callout).foregroundStyle(.secondary)
          }
          ForEach(folders) { folder in
            Surface {
              VStack(alignment: .leading, spacing: 5) {
                Text(folder.move.name).font(.headline)
                Text((folder.move.receipt.original.path as NSString).abbreviatingWithTildeInPath)
                  .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                LabeledContent(
                  "Çöp’e taşınan",
                  value: byteLabel(folder.move.receipt.bytes) + " · "
                    + folder.move.receipt.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(
                  "Yeniden ölçülen",
                  value: byteLabel(folder.bytes) + " · "
                    + folder.measuredAt.formatted(date: .abbreviated, time: .shortened))
              }.padding(12)
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
          ForEach(growth.prefix(8), id: \.0.id) { row, change in
            LabeledContent(row.name, value: "+" + byteLabel(change))
          }
        }
        SectionHead(title: "Son taramalar", note: "\(scan.history.count)")
        ForEach(scan.history) { saved in
          LabeledContent(
            saved.date.formatted(date: .abbreviated, time: .shortened),
            value: "\(saved.extended ? "Ayrıntılı" : "Hızlı") · \(saved.items.count) öğe")
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
