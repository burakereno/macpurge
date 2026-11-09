import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct ProjectRootsView: View {
  let scan: LiveScan
  @State private var picks = Set<String>()
  @State private var expanded = Set<String>()
  @State private var expandedBuilds = Set<String>()
  @State private var showAll = false
  @State private var cardMessage: String?
  @State private var removableRoots: [URL]?
  var body: some View {
    let cards = scan.projectCards
    let projectItems = cards.flatMap(\.outputs).compactMap(\.item)
    let choices = projectItems.filter {
      picks.contains($0.id) && scan.listMoveState($0) == .ready
    }
    let choose = MainAction(
      title: "Proje klasörü seç…", symbol: "folder.badge.plus", action: scan.chooseProjects)
    let clean = SafeTrashButton(scan: scan, group: .projects, items: projectItems,
      alwaysVisible: !scan.projects.isEmpty)
    Page {
      PageTitle(title: "Proje klasörleri") {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            choose.fixedSize()
            externalButton.fixedSize()
            Spacer(minLength: 8)
            clean.fixedSize()
          }
          VStack(alignment: .leading, spacing: 8) {
            choose
            externalButton
            clean
          }
        }
      }
    } content: {
      if let removableRoots {
        if removableRoots.isEmpty {
          Note(
            symbol: "externaldrive",
            text: "Bağlı yerel disklerde standart bir proje klasörü bulunamadı.")
        }
        ForEach(removableRoots, id: \.path) { url in
          Button("Taramaya ekle · \(url.path)") { scan.addProjects([url]) }
            .workspaceButton(.secondary)
            .disabled(scan.projects.contains(where: { $0.path == url.path }))
        }
      }
      if let note = scan.selectionNote { Note(symbol: "folder", text: note) }
      if scan.projects.isEmpty {
        ContentUnavailableView(
          "Henüz proje seçilmedi", systemImage: "folder",
          description: Text("Ölçmek istediğin bir veya daha fazla klasör seç.")
        )
        .frame(maxWidth: .infinity).padding(.vertical, 16)
      } else {
        InventoryList(scan.projects, id: \.path) { scope in
          InventoryReadout(
            title: scope.lastPathComponent, amount: "", subtitle: scope.path,
            location: scope, actionSymbol: "minus.circle", actionHelp: "Tarama listesinden çıkar",
            action: { scan.exclude(scope) })
        }
        if scan.phase != .finished { ScanStatus(scan: scan) }
        if scan.projectDiscovery.incomplete {
          Note(
            symbol: "exclamationmark.triangle",
            text: "Bazı klasörler okunamadı. Proje listesi eksik olabilir.")
        }
        if !cards.isEmpty {
          let checked = scan.phase == .finished && !scan.actions.isEmpty
          let candidates = cards.filter { $0.candidateBytes > 0 }
          let ranked = candidates.filter { $0.reclaimableBytes > 0 }
          let leaders = Array(ranked.prefix(5))
          let hasPreview = checked && !leaders.isEmpty
          let visible = hasPreview && !showAll ? leaders : cards
          VStack(alignment: .leading, spacing: 6) {
            if checked {
              Text("Yeniden oluşturulabilen alan").font(.headline)
              Text(byteLabel(scan.cleanupBytes(scan.safeMoves(projectItems))))
                .font(.largeTitle.bold()).monospacedDigit()
              Text(
                ReviewLanguage.format(
                  "%lld projeden %lld tanesinde toplam %@ seçilebilir klasör var.",
                  Int64(cards.count), Int64(candidates.count),
                  byteLabel(candidates.reduce(0) { $0 + $1.candidateBytes })))
              Text(
                ReviewLanguage.format(
                  "Yeniden kurulum veya içerik kontrolü gerektiren: %@",
                  byteLabel(
                    candidates.reduce(0) { $0 + $1.reclaimableBytes - $1.reproducibleBytes }))
              )
              .font(.caption).foregroundStyle(.secondary)
              Text(
                "Tahmin Çöp boşaltıldıktan sonraki alan içindir. Klasör dışına sabit bağlantısı olan dosyalar hariçtir."
              )
              .font(.caption).foregroundStyle(.secondary)
            } else {
              Text(ReviewLanguage.format("%lld proje bulundu", Int64(cards.count))).font(.headline)
              if scan.phase == .finished { Text("Kontrol ediliyor…").font(.callout) }
            }
          }
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(
                hasPreview && !showAll
                  ? ReviewLanguage.format(
                    "En çok alan açan %lld proje · %@", Int64(leaders.count),
                    byteLabel(
                      leaders.reduce(0) { $0 + $1.reclaimableBytes }))
                  : ReviewLanguage.text("Proje klasörleri")
              ).font(.headline)
              Spacer()
              if hasPreview && cards.count > leaders.count {
                Button(
                  showAll
                    ? ReviewLanguage.text("Daha az göster")
                    : ReviewLanguage.format("Tüm projeleri göster (%lld)", Int64(cards.count))
                ) { showAll.toggle() }
                .buttonStyle(.link)
              }
            }
            InventoryList(visible) { project in
              projectRow(project, checked: checked)
            }
          }
        } else if scan.phase.awaitsMeasurements {
          WorkspaceSkeleton(layout: .inventory, message: "Konumlar aranıyor…", rows: 3)
        } else if scan.phase == .finished {
          ContentUnavailableView(
            "Proje bulunamadı", systemImage: "folder.badge.questionmark",
            description: Text("Git deposu veya proje tanımı içeren bir klasör seç."))
        }
        if let cardMessage {
          Text(ReviewLanguage.text(cardMessage)).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !choices.isEmpty {
        WorkspaceListBar {
          HStack {
            Text(scan.selectionLabel(choices)).monospacedDigit()
            Spacer()
            Button("Seçilenleri Çöp’e taşı…") {
              scan.cleanup.prepare(choices, scan: scan, explicit: true)
            }
            .workspaceButton().disabled(scan.cleanup.busy)
          }
        }
        .overlay(alignment: .top) { Divider() }
      }
    }
    .onChange(of: scan.inventoryID) { picks.removeAll() }
    .onChange(of: scan.cleanup.outcome?.id) {
      if let outcome = scan.cleanup.outcome { picks.subtract(outcome.completedItems) }
    }
  }

  private func membership(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
      get: { set.wrappedValue.contains(id) },
      set: { on in
        if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
      })
  }

  private var selectedFolders: Binding<Set<String>> { $picks }

  private func projectRow(_ project: ProjectFolderRow, checked: Bool) -> some View {
    let outputs = project.outputs.sorted {
      let a = $0.bytes ?? -1
      let b = $1.bytes ?? -1
      return a == b ? $0.path < $1.path : a > b
    }
    let estimate = outputs.reduce(0) { $0 + $1.reclaimableBytes }
    let largest = outputs.filter { $0.reclaimableBytes > 0 }.prefix(2)
    let detail = largest.map { $0.title + " " + byteLabel($0.reclaimableBytes) }.joined(
      separator: " · ")
    let size = project.bytes.map {
      ReviewLanguage.format(
        "Proje boyutu: %@",
        (project.approximate ? "≈ " : project.partial ? "≥ " : "") + byteLabel($0))
    }
    let selectable = regenerableItems(outputs)
    return InventoryDisclosure(
      isExpanded: membership(project.id, in: $expanded), selectable: selectable,
      selected: selectedFolders, busy: scan.cleanup.busy,
      selectionHelp: "Yeniden oluşturulabilenleri seç"
    ) {
      VStack(alignment: .leading, spacing: 0) {
        Text(project.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          .padding(.leading, InventoryLayout.detailIndent).padding(
            .vertical, InventoryLayout.verticalPadding)
        if project.outputs.isEmpty {
          Text("Bilinen önbellek veya derleme klasörü bulunamadı.").font(.callout)
            .padding(.leading, InventoryLayout.detailIndent)
            .padding(.vertical, InventoryLayout.verticalPadding)
        }
        InventoryRows(project.outputGroups) { group in outputGroup(group) }
        InventoryRows(project.artifacts.sorted { $0.bytes > $1.bytes }, id: \.url.path) {
          artifact in
          InventoryReadout(
            title: artifact.url.lastPathComponent, amount: byteLabel(artifact.bytes),
            symbol: "hammer", subtitle: ReviewLanguage.text("Proje dışındaki DerivedData"),
            location: artifact.url)
        }
        if let date = project.sourceModified {
          InventoryReadout(
            title: ReviewLanguage.text("Son kaynak değişikliği"),
            amount: date.reviewDate(date: .abbreviated, time: .omitted), symbol: "clock")
        }
      }
    } label: {
      InventoryGroupHeader(
        title: project.label, symbol: "folder", tint: Ink.sea,
        amount: checked ? byteLabel(estimate) : "…",
        subtitle: detail.isEmpty ? size : detail
      ) {
        EmptyView()
      }
    } accessory: {
      cleanupButton(selectable)
    }
    .contextMenu {
      Button("İsimsiz özet kartını kopyala") {
        cardMessage =
          AnonymousCard.copy(bytes: project.bytes ?? 0, build: project.localOutputBytes)
          ? "İsimsiz kart kopyalandı." : "Kart hazırlanamadı."
      }.disabled(project.bytes == nil)
    }
  }

  private func regenerableItems(_ outputs: [ProjectFolderRow.Output]) -> [ReportItem] {
    outputs.filter(\.isReproducible).compactMap(\.item).filter { scan.listMoveState($0) == .ready }
  }

  private func cleanupButton(_ items: [ReportItem]) -> some View {
    Button {
      scan.cleanup.prepare(items, scan: scan, explicit: true)
    } label: {
      Image(systemName: "trash").frame(width: InventoryLayout.actionWidth, height: 26)
    }.buttonStyle(.plain).disabled(items.isEmpty || scan.cleanup.busy)
      .help("Önbellek ve derleme çıktılarını Çöp’e taşı…")
      .accessibilityLabel(ReviewLanguage.text("Önbellek ve derleme çıktılarını Çöp’e taşı…"))
  }

  @ViewBuilder private func outputGroup(_ group: ProjectFolderRow.OutputGroup) -> some View {
    if group.isBuildFolder {
      let selectable = regenerableItems(group.outputs)
      let keep = group.outputs.filter { !$0.isReproducible }.reduce(0) { $0 + $1.countedBytes }
      InventoryDisclosure(
        isExpanded: membership(group.id, in: $expandedBuilds), selectable: selectable,
        selected: selectedFolders, busy: scan.cleanup.busy,
        selectionHelp: "Yeniden oluşturulabilenleri seç"
      ) {
        InventoryRows(group.outputs) { output in outputRow(output) }
      } label: {
        InventoryGroupHeader(
          title: group.title, symbol: "folder", tint: Ink.sea, amount: byteLabel(group.bytes),
          subtitle: ReviewLanguage.format(
            "Yeniden oluşan %@ · Yedek ve özel dosyalar %@",
            byteLabel(group.reproducibleBytes), byteLabel(keep))
        ) { EmptyView() }
      } accessory: {
        cleanupButton(selectable)
      }
    } else {
      InventoryRows(group.outputs) { output in outputRow(output) }
    }
  }

  private func outputRow(_ output: ProjectFolderRow.Output) -> some View {
    let item = output.item
    let reason =
      item.flatMap { scan.action(for: $0).availability.explanation }
      ?? ReviewLanguage.text(output.effect)
    let estimate =
      output.candidateBytes > 0 && (output.bytes ?? 0) > output.reclaimableBytes
      ? ReviewLanguage.format("Tahmini kazanım: %@", byteLabel(output.reclaimableBytes)) + " · "
      : ""
    return Group {
      if let item {
        InventoryMeasuredRow(
          scan: scan, item: item, selected: selectedFolders,
          root: scan.roots.first { $0.group == .projects && $0.url.path == output.path },
          amount: output.bytes.map(byteLabel) ?? ReviewLanguage.text("Ölçülmedi"),
          title: output.title, caption: estimate + reason)
      } else {
        InventoryRow(
          scan: scan, item: nil, title: output.title,
          amount: output.bytes.map(byteLabel) ?? ReviewLanguage.text("Ölçülmedi"),
          location: URL(fileURLWithPath: output.path), selected: selectedFolders,
          caption: estimate + reason)
      }
    }
  }

  private var externalButton: some View {
    MainAction(title: "Harici disklerde proje klasörü bul", symbol: "externaldrive") {
      Task { removableRoots = await ExternalProjects.suggestions() }
    }
  }
}
