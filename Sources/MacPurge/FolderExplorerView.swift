import SwiftUI
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

@MainActor @Observable final class ExplorerSession {
  private(set) var snapshot: ExplorerSnapshot?
  private(set) var busy = false
  private(set) var error: String?
  private(set) var parent: String?
  private(set) var rows: [ExplorerEntry] = []
  private(set) var scope: URL?
  var mode: ExplorerMode = .folders
  var kind: ExplorerKind?
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var filtering: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var filterID = UUID()

  func load(_ root: URL, exclusions: [URL]) {
    stop()
    let token = UUID(); generation = token
    if scope != root { snapshot = nil; rows = []; parent = nil }
    scope = root; busy = true; error = nil
    work = Task {
      defer { if generation == token { busy = false; work = nil } }
      do {
        let index = try await ScanExclusions.$current.withValue(.init(paths: exclusions.map(\.path))) {
          try await FolderExplorer.scan(root: root)
        }
        guard !Task.isCancelled, generation == token else { return }
        snapshot = index
        if parent.flatMap({ index.entries[$0] })?.directory != true { parent = root.path }
      } catch is CancellationError {
        if generation == token { error = ReviewLanguage.text("Folder scan stopped. Previous measurements are kept.") }
      } catch {
        if generation == token { self.error = error.localizedDescription }
      }
    }
  }

  func navigate(_ path: String) {
    guard snapshot?.entries[path]?.directory == true else { return }
    parent = path
  }

  func filter(_ query: String) {
    filtering?.cancel()
    let token = UUID(); filterID = token
    guard let snapshot, let parent else { rows = []; return }
    let mode = mode, kind = kind
    filtering = Task {
      let result = await Self.select(snapshot, parent: parent, mode: mode, query: query, kind: kind)
      guard !Task.isCancelled, filterID == token else { return }
      rows = result
    }
  }
  @concurrent private static func select(_ snapshot: ExplorerSnapshot, parent: String,
                                         mode: ExplorerMode, query: String, kind: ExplorerKind?) async -> [ExplorerEntry] {
    snapshot.rows(parent: parent, mode: mode, query: query, kind: kind)
  }
  func stop() { work?.cancel() }
  func invalidate() {
    generation = UUID(); filterID = UUID()
    work?.cancel(); filtering?.cancel(); work = nil; busy = false
    snapshot = nil; rows = []; parent = nil
    error = ReviewLanguage.text("Scan exclusions changed. Rescan the selected folder.")
  }
}

struct FolderExplorerView: View {
  let scan: LiveScan
  let contentInset: CGFloat
  var query = ""
  @State private var session = ExplorerSession()
  @State private var selection: String?
  @State private var inspecting: ExplorerEntry?

  private var filterKey: String {
    [query, session.parent ?? "", session.mode.rawValue, session.kind?.rawValue ?? "", session.snapshot?.id.uuidString ?? ""].joined(separator: "\0")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack { folderActions; Spacer(); viewFilters }
        VStack(alignment: .leading, spacing: 8) { folderActions; viewFilters }
      }
      .padding(.horizontal, contentInset)
      if let index = session.snapshot, let parent = session.parent {
        ScrollView(.horizontal) {
          HStack(spacing: 5) {
            ForEach(index.breadcrumbs(to: parent)) { row in
              Button(row.name.isEmpty ? "/" : row.name) { selection = nil; session.navigate(row.path) }
                .buttonStyle(.borderless).help(row.path)
              if row.path != parent { Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true) }
            }
          }
        }.fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, contentInset)
        Group {
          Text(index.root.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled).help(index.root.path)
          Text("Read-only measurements. File size alone does not mean a file is no longer needed.")
            .font(.caption).foregroundStyle(.secondary)
          if index.limited || index.skipped > 0 {
            Text("Some entries were not measured or the scan limit was reached. Folder totals marked ≥ are lower bounds.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if index.excluded > 0 {
            Text("Configured scan exclusions are omitted from this scope.").font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, contentInset)
        fileTable
        HStack {
          Text(ReviewLanguage.format("%lld results · measured %@", Int64(session.rows.count), index.date.reviewDate(date: .abbreviated, time: .shortened)))
          Spacer()
          if let row = selectedRow {
            if row.directory { Button("Open folder") { session.navigate(row.path); selection = nil } }
            Button("Ayrıntıları göster") { inspecting = row }
          }
        }.font(.caption).padding(.horizontal, contentInset)
        if session.mode == .largest {
          Text("Up to 500 largest matching files in the current folder and its descendants. Hard-linked paths are counted once.")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, contentInset)
        }
      } else if session.busy {
        WorkspaceSkeleton(layout: .table, message: "Konumlar aranıyor…", rows: 7)
          .padding(.horizontal, contentInset)
          .frame(maxHeight: .infinity, alignment: .top)
      } else {
        ContentUnavailableView("Choose a folder to explore", systemImage: "folder.badge.magnifyingglass",
          description: Text("The selected folder is measured once. Browsing and filtering reuse those measurements."))
          .padding(.horizontal, contentInset)
      }
      if let error = session.error {
        Text(error).font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, contentInset)
      }
    }
    .task(id: filterKey) { session.filter(query) }
    .onChange(of: scan.excludedFolders) { session.invalidate() }
    .onDisappear { session.stop() }
    .sheet(item: $inspecting) { row in explorerDetails(row) }
  }

  private var folderActions: some View {
    HStack(spacing: 8) {
      Button("Choose explorer folder…") {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let folder = panel.url {
          selection = nil
          session.load(folder, exclusions: scan.excludedFolders)
        }
      }.disabled(session.busy)
      if session.busy {
        if session.snapshot != nil { WorkspaceActivityIndicator(label: "Konumlar aranıyor…") }
        Button("Durdur") { session.stop() }
      } else if let folder = session.scope {
        Button("Rescan folder") { session.load(folder, exclusions: scan.excludedFolders) }
      }
    }
  }

  private var viewFilters: some View {
    HStack(spacing: 8) {
      WorkspaceTabs(label: "Explorer view", choices: ExplorerMode.allCases, selection: $session.mode) {
        Text(ReviewLanguage.text($0.rawValue))
      }.fixedSize()
      WorkspacePicker(label: "File type", choices: [nil] + ExplorerKind.allCases.map(Optional.some),
        selection: $session.kind, width: 155) { kind in
        Text(ReviewLanguage.text(kind?.rawValue ?? "All file types"))
      }
    }
  }

  private var selectedRow: ExplorerEntry? { selection.flatMap { session.snapshot?.entries[$0] } }

  private var fileTable: some View {
    Table(session.rows, selection: $selection) {
      TableColumn("Öğe") { row in
        Label(row.name, systemImage: row.directory ? "folder" : "doc")
          .lineLimit(1).truncationMode(.middle).help(row.path)
      }.width(min: 160, ideal: 250)
      TableColumn("Etiket") { row in Text(ReviewLanguage.text(row.kind.rawValue)).font(.caption) }
        .width(min: 90, ideal: 120)
      TableColumn("Boyut") { row in
        Text(row.bytes.map { (row.partial ? "≥ " : "") + byteLabel($0) } ?? "—").monospacedDigit()
      }.width(min: 75, ideal: 100).alignment(.trailing)
      TableColumn("Fark") { _ in Text("—").foregroundStyle(.secondary) }
        .width(min: 40, ideal: 50).alignment(.trailing)
      TableColumn("Değişiklik") { row in
        Text(row.modified.reviewDate(date: .abbreviated, time: .omitted)).font(.caption)
      }.width(min: 75, ideal: 100)
      TableColumn("İşlem") { row in
        Button { InventoryLocation.open(URL(fileURLWithPath: row.path)) } label: { Image(systemName: "folder") }
          .buttonStyle(.plain).help("Finder’da aç").accessibilityLabel(ReviewLanguage.text("Finder’da aç"))
      }.width(54)
    }
    .storageTableScroller(contentInset: contentInset)
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let row = session.snapshot?.entries[id] {
        if row.directory { Button("Open folder") { session.navigate(id); selection = nil } }
        Button("Ayrıntıları göster") { inspecting = row }
        Button("Finder’da aç") { InventoryLocation.open(URL(fileURLWithPath: id)) }
      }
    } primaryAction: { ids in
      if let id = ids.first, let row = session.snapshot?.entries[id] {
        if row.directory { session.navigate(id); selection = nil } else { inspecting = row }
      }
    }
    .overlay {
      if session.rows.isEmpty { Text("No matching entries in the measured scope.").foregroundStyle(.secondary) }
    }
  }

  private func explorerDetails(_ row: ExplorerEntry) -> some View {
    let details = [
      ("Allocated size", row.bytes.map { (row.partial ? "≥ " : "") + byteLabel($0) } ?? "—", "internaldrive", nil as String?),
    ] + (row.logicalBytes.map { [("Logical size", byteLabel($0), "doc", nil as String?)] } ?? [])
      + [("Son dosya değişikliği", "", "clock", Optional(row.modified.reviewDate(date: .abbreviated, time: .shortened)))]
    return VStack(alignment: .leading, spacing: 14) {
      Text(row.name).font(.title2.bold()).lineLimit(2)
      Text(row.path).font(.caption.monospaced()).textSelection(.enabled)
      InventoryList(details, id: \.0) { title, amount, symbol, subtitle in
        InventoryReadout(title: ReviewLanguage.text(title), amount: amount, symbol: symbol, subtitle: subtitle)
      }
      Text("Each folder total counts a hard-linked file once within that folder. Sibling totals may overlap. APFS clones may share blocks; these sizes are not cleanup estimates.")
        .font(.caption).foregroundStyle(.secondary)
      if row.hardLinks > 1 { Text("This file has multiple hard-linked paths.").font(.caption) }
      if row.partial { Text("This measurement is incomplete and may be a lower bound.").font(.caption) }
      HStack { Button("Finder’da aç") { InventoryLocation.open(URL(fileURLWithPath: row.path)) }; Spacer(); Button("Bitti") { inspecting = nil } }
    }.padding(22).frame(width: 540)
  }
}
