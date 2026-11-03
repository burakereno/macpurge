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
  @State private var inspecting = false
  private var report: ScanReport? {
    scan.phase == .running && scan.detailed ? scan.storagePreview : scan.report
  }
  private var visible: [ReportItem] {
    (report?.items ?? []).filter {
      !scan.hiddenIDs.contains($0.id) && (category == nil || $0.category == category?.rawValue)
        && (filter == .all
          || (filter == .unavailable ? !$0.complete : $0.safety == filter.rawValue))
        && (text.isEmpty
          || [
            $0.name, $0.category, $0.path,
            ScanGroup(rawValue: $0.category).map { ReviewLanguage.text($0.titleKey) } ?? "",
          ].contains(where: {
            $0.localizedCaseInsensitiveContains(text)
          }))
    }.sorted(using: sorting)
  }

  var body: some View {
    GeometryReader { viewport in
      VStack(alignment: .leading, spacing: 12) {
        PageTitle(
          kicker: "Çalışma alanı", title: "Depolama",
          subtitle: listing
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
              report: report, pending: scan.phase == .running ? scan.pendingCategories : []
            ) { group in
              category = group
              showsItems = true
              focus = nil
            }.frame(width: slot.size.width, height: slot.size.height)
          }
        }
        HStack {
          if listing {
            Text("\(visible.count) öğe · \(selected.count) seçim").font(.caption).foregroundStyle(
              .secondary)
          } else if let report {
            Text(ReviewLanguage.text(report.extended ? "Ayrıntılı tarama" : "Hızlı tarama"))
              .font(.caption.weight(.semibold))
            Text(report.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(
              .secondary)
          }
          Spacer()
          if listing {
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
      if let item = report?.items.first(where: { $0.id == focus }) { ItemInspector(item: item) }
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

  private var storageTable: some View {
    Table(visible, selection: $focus, sortOrder: $sorting) {
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
      TableColumn("Değişiklik", value: \.sortDate) { row in
        Text(row.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").font(
          .caption
        ).foregroundStyle(.secondary)
      }.width(min: 68, ideal: 90, max: 116)
      TableColumn("Plan") { row in
        if row.eligibleBytes > 0 {
          Toggle(
            "Plana ekle: \(row.name)",
            isOn: Binding(
              get: { selected.contains(row.id) },
              set: { value in
                if value { selected.insert(row.id) } else { selected.remove(row.id) }
              })
          ).toggleStyle(.checkbox).labelsHidden().disabled(scan.phase == .running)
        }
      }.width(39)
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
  fileprivate var sortDate: Date { modified ?? .distantPast }
}

struct ItemInspector: View {
  let item: ReportItem
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      SectionHead(
        title: item.name, note: ScanGroup(rawValue: item.category)?.titleKey ?? item.category)
      if let label = item.safety, let level = SafetyLevel(rawValue: label) {
        SafetyBadge(level: level)
      }
      Text(ReviewLanguage.text(item.reason)).fixedSize(horizontal: false, vertical: true)
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
          selected.contains($0.id) && !scan.hiddenIDs.contains($0.id) && $0.eligibleBytes > 0
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
                selected = Set(report.plan(target: goal, excluding: scan.hiddenIDs).map(\.id))
              }
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
        Note(
          symbol: "eye",
          text:
            "Bu bir önizlemedir. Boyut, tek diskte ölçülen adayların tahminidir. Gerçek boş alandaki değişim 0 bayttır."
        )
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
        let prior = scan.history.dropFirst().first(where: { $0.extended == current.extended })
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
        let unusual = current.unusualGroups(previous: scan.history)
        if !unusual.isEmpty {
          SectionHead(title: "Olağandışı artışlar")
          ForEach(unusual, id: \.0) { group, _, delta in
            LabeledContent(group, value: "+" + byteLabel(delta))
          }
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
