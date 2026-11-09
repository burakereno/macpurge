import SwiftUI
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

@MainActor @Observable final class DuplicateSession {
  private(set) var report: DuplicateReport?
  private(set) var folder: URL?
  private(set) var busy = false
  private(set) var error: String?
  private(set) var outcome: TrashOutcome?
  var selected = Set<String>()
  var preview: TrashPlan?
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var inventoryID: UUID?

  func search(_ root: URL, home: URL, exclusions: [URL], inventoryID: UUID) {
    guard !busy else { return }
    folder = root
    report = nil; selected = []; error = nil; outcome = nil
    let token = UUID(); generation = token
    self.inventoryID = inventoryID
    busy = true
    work = Task {
      defer { if generation == token { busy = false; work = nil } }
      do {
        let result = try await ScanExclusions.$current.withValue(.init(paths: exclusions.map(\.path))) {
          try await DuplicateInventory.scan(root: root, home: home)
        }
        guard !Task.isCancelled, generation == token else { return }
        report = result
      } catch is CancellationError { error = ReviewLanguage.text("Search stopped. No files were changed.") }
      catch { self.error = error.localizedDescription }
    }
  }

  func prepare(scan: LiveScan) {
    guard inventoryID == scan.inventoryID else { error = ReviewLanguage.text("The folder or scan settings changed. Search again."); return }
    guard !busy, inventoryID == scan.inventoryID, !scan.cleanup.busy, let report else { return }
    busy = true
    work = Task {
      defer { busy = false; work = nil }
      do {
        preview = try await ScanExclusions.$current.withValue(.init(paths: scan.excludedFolders.map(\.path))) {
          try await report.plan(selected: selected, engine: scan.cleanup.engine)
        }
      }
      catch { self.error = error.localizedDescription }
    }
  }

  func confirm(_ id: UUID, acknowledged: Bool, scan: LiveScan) {
    guard !busy, inventoryID == scan.inventoryID, !scan.cleanup.busy,
      let confirmed = ConfirmedTrashPlan(confirming: id, preview: &preview, currentReportID: report?.id,
        acknowledgedReview: acknowledged) else { return }
    guard scan.cleanup.beginExternalOperation() else { return }
    busy = true
    work = Task {
      defer { busy = false; work = nil; scan.cleanup.endExternalOperation() }
      let result = await scan.cleanup.engine.apply(confirmed)
      outcome = result
      await Task {
        await scan.refreshAfterCleanup(result.moved, restored: false, disk: result.diskAfter)
        await scan.cleanup.refresh()
      }.value
      report = nil; selected = []
    }
  }
  func stop() { work?.cancel() }
}

struct DuplicatesView: View {
  let scan: LiveScan
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  @State private var session = DuplicateSession()
  @State private var focused: String?
  @State private var acknowledged = false

  var body: some View {
    WorkspacePage {
      VStack(alignment: .leading, spacing: 0) {
        PageTitle(title: "Duplicates")
        if session.error != nil || session.outcome != nil {
          VStack(alignment: .leading, spacing: 12) {
            if let error = session.error { Note(symbol: "exclamationmark.circle", text: error) }
            if let result = session.outcome {
              Note(symbol: "trash", text: ReviewLanguage.format("Moved to Trash: %lld items", Int64(result.moved.count)))
              ForEach(result.notices, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            }
          }
          .padding(.bottom, WorkspaceLayout.headerVerticalInset)
        }
      }
    } content: { inset in
      VStack(alignment: .leading, spacing: 0) {
        if let report = session.report {
          results(report, inset: inset)
        } else if session.busy {
          WorkspaceListBar {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text("Comparing files…").font(.callout.weight(.medium))
                if let folder = session.folder {
                  Text(folder.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(folder.path)
                }
              }
              Spacer()
              Button("Durdur") { session.stop() }
                .workspaceButton(.secondary)
            }
          }
          WorkspaceSkeleton(layout: .table, message: "Comparing files…", rows: 7)
            .padding(inset)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
          WorkspaceEmptyState(symbol: "doc.on.doc", title: "Find duplicate files",
            description: "Choose a personal folder to compare file contents. Application data, bundles and dependencies are skipped.",
            note: "Files smaller than 1 MB are skipped.") {
            chooseFolderButton
          }
        }
      }
    }
    .focusedSceneValue(\.focusWorkspaceSearch,
      session.report?.groups.isEmpty == false ? { searchFocused = true } : nil)
    .onDisappear { session.stop() }
    .sheet(item: $session.preview) { plan in
      VStack(alignment: .leading, spacing: 14) {
        Text("Review duplicate copies").font(.title2.bold())
        Text("Only the listed copies will move to the Trash. A verified identical copy remains in every group.")
        Text(ReviewLanguage.format("Tahmini kazanım: %@", byteLabel(plan.reclaimableBytes))).font(.headline)
        Text("Shared or unknown clone allocation is excluded from the recovery estimate.").font(.caption)
        Text("Space is freed only after the Trash is emptied. Restore is available in Space plan.").font(.caption)
        ScrollView {
          InventoryList(plan.targets) { target in
            InventoryReadout(title: target.name, amount: byteLabel(target.snapshot.reclaimableBytes),
              symbol: "doc.on.doc", subtitle: target.path.path)
          }
          ForEach(plan.skipped, id: \.self) { Text($0).font(.caption) }
        }.frame(maxHeight: 300)
        Toggle("Belirtilen riskleri okudum ve kabul ediyorum.", isOn: $acknowledged).toggleStyle(.checkbox)
        HStack {
          Spacer()
          Button("Vazgeç") { session.preview = nil }
            .workspaceButton(.secondary)
          Button("Çöp’e taşı", role: .destructive) { session.confirm(plan.id, acknowledged: acknowledged, scan: scan) }
            .workspaceButton(.destructive)
            .disabled(!acknowledged || plan.targets.isEmpty)
        }
      }.padding(22).frame(width: 540)
    }
  }

  private var chooseFolderButton: some View {
    Button(action: chooseFolder) {
      Label("Choose duplicate search folder…", systemImage: "folder.badge.plus")
    }
    .workspaceButton()
    .disabled(session.busy || scan.cleanup.busy)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    query = ""
    focused = nil
    session.search(url, home: scan.cleanup.engine.home, exclusions: scan.excludedFolders,
      inventoryID: scan.inventoryID)
  }

  private func results(_ report: DuplicateReport, inset: CGFloat) -> some View {
    let rows = report.groups.flatMap { group in group.files.map { DuplicateFileRow(file: $0, group: group) } }
      .filter { query.isEmpty || $0.file.path.localizedCaseInsensitiveContains(query) }
    return Group {
      if report.groups.isEmpty {
        WorkspaceEmptyState(symbol: "checkmark.circle", title: "No duplicate files found",
          description: "No identical files were found in the compared scope.") {
          chooseFolderButton
        }
      } else if rows.isEmpty {
        WorkspaceEmptyState(symbol: "magnifyingglass", title: "Sonuç yok",
          description: "Try another file name or path.") {
          Button("Clear search") { query = "" }
            .workspaceButton(.secondary)
        }
      } else {
        resultsTable(rows, contentInset: inset)
          .padding(.top, inset)
      }
    }
    .workspaceListControls {
      VStack(alignment: .leading, spacing: 8) {
        Text(report.root.path).font(.caption.monospaced()).textSelection(.enabled)
        if report.limited || report.unreadable > 0 {
          Text("Some files were skipped or the comparison budget was reached. Results cover only verified files.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !report.groups.isEmpty {
          HStack {
            chooseFolderButton
            if session.busy {
              WorkspaceActivityIndicator(label: "Kontrol ediliyor…")
              Button("Durdur") { session.stop() }
                .workspaceButton(.secondary)
            }
            Spacer()
            WorkspaceSearchField(prompt: "Search duplicate files", text: $query, focused: $searchFocused)
              .frame(maxWidth: 240)
            Button("Review duplicate copies…") { acknowledged = false; session.prepare(scan: scan) }
              .workspaceButton()
              .disabled(session.selected.isEmpty || session.busy || scan.cleanup.busy)
          }
        }
      }
    }
  }

  private func resultsTable(_ rows: [DuplicateFileRow], contentInset: CGFloat) -> some View {
    Table(rows, selection: $focused) {
      TableColumn("Öğe") { row in
        HStack(spacing: InventoryLayout.controlSpacing) {
          Toggle("Select this copy", isOn: Binding(get: { session.selected.contains(row.id) }, set: { on in
            if on {
              guard row.group.files.filter({ !session.selected.contains($0.path) }).count > 1 else { return }
              session.selected.insert(row.id)
            } else { session.selected.remove(row.id) }
          })).labelsHidden().toggleStyle(.checkbox).frame(width: InventoryLayout.selectionWidth)
            .disabled(row.file.links > 1 || session.busy)
            .help(ReviewLanguage.text(row.file.links > 1 ? "Hard-linked files are inspection-only." : "Keep at least one copy of every duplicate group."))
          Text(URL(fileURLWithPath: row.id).lastPathComponent).lineLimit(1).truncationMode(.middle).help(row.id)
        }
      }.width(min: 140, ideal: 230)
      TableColumn("Etiket") { row in
        Text(ReviewLanguage.format("%lld copies · %@", Int64(row.group.files.count), row.group.id.prefix(4).map { String(format: "%02x", $0) }.joined()))
          .font(.caption).help(row.group.id.map { String(format: "%02x", $0) }.joined())
      }.width(min: 100, ideal: 150)
      TableColumn("Boyut") { row in Text(byteLabel(row.file.allocatedBytes)).monospacedDigit() }
        .width(min: 75, ideal: 90).alignment(.trailing)
      TableColumn("Estimated recovery") { row in
        Text(row.file.mayShareBlocks == false && row.file.links == 1 ? byteLabel(row.file.allocatedBytes) : "—").monospacedDigit()
      }.width(min: 90, ideal: 110).alignment(.trailing)
      TableColumn("Değişiklik") { row in
        Text(Date(timeIntervalSince1970: Double(row.file.modifiedSeconds)).reviewDate(date: .abbreviated, time: .omitted)).font(.caption)
      }.width(min: 75, ideal: 100)
      TableColumn("İşlem") { row in
        Button { InventoryLocation.open(URL(fileURLWithPath: row.id)) } label: { Image(systemName: "folder") }
          .buttonStyle(.plain).help("Finder’da aç").accessibilityLabel(ReviewLanguage.text("Finder’da aç"))
      }.width(54)
    }
    .storageTableScroller(contentInset: 0)
    .padding(.horizontal, contentInset)
  }
}

private struct DuplicateFileRow: Identifiable {
  let file: FileProof
  let group: DuplicateGroup
  var id: String { file.path }
}
