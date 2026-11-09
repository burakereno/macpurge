import AppKit
import SwiftUI

#if SWIFT_PACKAGE
import MacPurgeCore
#endif

private extension ApplicationUninstall.Kind {
  var symbol: String {
    switch self {
    case .bundle: "app"
    case .cache: "externaldrive"
    case .preferences: "gearshape"
    case .data: "folder"
    case .logs: "doc.text"
    case .shared: "shippingbox"
    case .background: "gearshape.2"
    }
  }
}

struct ApplicationUninstallView: View {
  let scan: LiveScan
  @State private var apps: [ApplicationInventory.Installed] = []
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  @State private var app: ApplicationInventory.Installed?
  @State private var inspection: ApplicationUninstall.Inspection?
  @State private var inspectedInventory: UUID?
  @State private var selected: Set<String> = []
  @State private var catalogRevision = 0
  @State private var detailRevision = 0
  @State private var catalogLoading = true
  @State private var catalogError: String?
  @State private var detailError: String?

  private struct CatalogRequest: Hashable {
    let exclusions: [URL]
    let revision: Int
    let outcome: UUID?
  }

  private struct DetailRequest: Hashable {
    let app: String?
    let inventory: UUID
    let revision: Int
    let outcome: UUID?
  }

  private var uninstallOutcome: TrashOutcome? {
    guard let result = scan.cleanup.outcome, result.applicationUninstall else { return nil }
    return result
  }

  var body: some View {
    Group {
      if let app { details(app) } else { catalog }
    }
    .task(id: CatalogRequest(exclusions: scan.excludedFolders, revision: catalogRevision, outcome: uninstallOutcome?.id)) {
      await loadCatalog()
    }
    .task(id: DetailRequest(app: app?.id, inventory: scan.inventoryID, revision: detailRevision, outcome: uninstallOutcome?.id)) {
      await loadDetails()
    }
  }

  private var catalog: some View {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matches = apps.filter { term.isEmpty || [$0.identity.name, $0.identity.bundleID, $0.id]
      .contains { $0.localizedCaseInsensitiveContains(term) } }
    return WorkspacePage {
      VStack(alignment: .leading, spacing: 0) {
        PageTitle(title: "Uninstall Apps")
        outcome
      }
    } content: { inset in
      VStack(alignment: .leading, spacing: 0) {
        Divider()
        Group {
          if catalogLoading && apps.isEmpty {
            WorkspaceSkeleton(layout: .applications, message: "Finding installed applications…", rows: 8)
              .padding(.horizontal, inset)
              .padding(.top, inset)
              .frame(maxHeight: .infinity, alignment: .top)
          } else if matches.isEmpty && catalogError == nil {
            ContentUnavailableView("No applications found.", systemImage: "magnifyingglass")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            InstalledApplicationCards(apps: matches, footprints: scan.storageReport?.applications ?? [],
              contentInset: inset) { app = $0 }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .workspaceListControls {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Applications").font(.headline)
              Text(matches.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
              Spacer()
              WorkspaceSearchField(prompt: "Search applications", text: $query, focused: $searchFocused)
                .frame(idealWidth: 230, maxWidth: 270)
              Button {
                catalogRevision += 1
              } label: { Label("Refresh applications", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
              .workspaceButton(.secondary)
              .help("Refresh applications").disabled(catalogLoading)
            }
            if let catalogError { Note(symbol: "exclamationmark.triangle", text: catalogError) }
          }
        }
      }
    }
    .focusedSceneValue(\.focusWorkspaceSearch, { searchFocused = true })
  }

  private func details(_ app: ApplicationInventory.Installed) -> some View {
    Page(contentBottomInset: 0) {
      PageTitle(title: Text(verbatim: app.identity.name)) {
        HStack(spacing: 8) {
          WorkspaceBackButton(title: "All applications") { self.app = nil }
          Spacer(minLength: 0)
          Button {
            detailRevision += 1
          } label: { Label("Rescan app files", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
          .workspaceButton(.secondary)
          .help("Rescan app files").disabled(scan.cleanup.busy)
        }
      }
    } controls: {
      if let inspection {
        WorkspaceListBar { selectAppFiles(inspection, app: app) }
      }
    } content: {
      outcome
      if let detailError {
        Note(symbol: "exclamationmark.triangle", text: detailError)
      } else if let inspection {
        fileRows(inspection, app: app)
      } else {
        WorkspaceSkeleton(layout: .detailInventory, message: "Checking the app and its related files…")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let inspection {
        WorkspaceListBar { footer(inspection, app: app) }
          .overlay(alignment: .top) { Divider() }
      }
    }
  }

  private func selectAppFiles(_ inspection: ApplicationUninstall.Inspection, app: ApplicationInventory.Installed) -> some View {
    let selections = inspection.selectableIDs.map { id in
      Binding(get: { selected.contains(id) }, set: { on in
        guard id != app.id else { return }
        if on { selected.insert(id) } else { selected.remove(id) }
      })
    }
    return Toggle(sources: selections.isEmpty ? [.constant(false)] : selections, isOn: \.self) {
      Text("Select all").font(.callout.weight(.medium))
    }
    .toggleStyle(.checkbox)
    .disabled(selections.count <= 1 || scan.cleanup.busy)
  }

  private func fileRows(_ inspection: ApplicationUninstall.Inspection, app: ApplicationInventory.Installed) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let blocker = inspection.blocker { Note(symbol: "lock.circle", text: blocker) }
      InventoryList(inspection.rows, borderless: true) { row in
        let action: CleanupAction = if row.action.availability == .ready, let blocker = inspection.blocker {
          .unavailable(.blocked(ReviewLanguage.text(blocker)))
        } else { row.action }
        let kind = row.candidate.match.kind
        let matchNote = row.candidate.match.byName ? " · " + ReviewLanguage.text("Matched by name") : ""
        InventoryRow(scan: scan, item: nil, title: row.title,
          amount: row.target == nil ? "—" : byteLabel(row.action.bytes),
          location: row.candidate.url, selected: $selected,
          caption: ReviewLanguage.text(kind.title) + matchNote + " · " + row.candidate.url.path,
          fileSelection: .init(id: row.id, action: action, symbol: kind.symbol,
            iconPath: kind == .bundle ? app.id : nil, required: row.id == app.id))
      }
      if !inspection.unreadable.isEmpty {
        DisclosureGroup("Inaccessible locations") {
          ForEach(inspection.unreadable, id: \.self) { path in
            Text(path).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var outcome: some View {
    if let result = uninstallOutcome {
      if !result.moved.isEmpty {
        Note(symbol: "checkmark.circle", text: ReviewLanguage.format(
          "Uninstall moved %lld items to the Trash. Restore them from Space plan.", Int64(result.moved.count)))
      }
      if !result.notices.isEmpty {
        DisclosureGroup(result.moved.isEmpty ? "The application could not be removed" : "Some selected files were kept") {
          ForEach(Array(result.notices.enumerated()), id: \.offset) { _, notice in
            Text(notice).font(.callout).textSelection(.enabled)
          }
        }
      }
    }
  }

  private func loadCatalog() async {
    catalogLoading = true
    catalogError = nil
    do {
      let installed = try await ApplicationUninstall.catalog(home: scan.cleanup.engine.home, exclusions: scan.excludedFolders)
      try Task.checkCancellation()
      apps = installed
      if let app, !installed.contains(where: { $0.id == app.id }) { self.app = nil }
    } catch is CancellationError { return }
    catch { catalogError = error.localizedDescription }
    catalogLoading = false
  }

  private func loadDetails() async {
    inspection = nil
    inspectedInventory = nil
    selected = []
    detailError = nil
    guard let app else { return }
    let inventory = scan.inventoryID
    do {
      let result = try await scan.cleanup.engine.inspectApplication(app.identity,
        projects: scan.protectedProjects, exclusions: scan.excludedFolders)
      try Task.checkCancellation()
      inspection = result
      inspectedInventory = inventory
      selected = Set(result.selectableIDs)
    } catch is CancellationError { return }
    catch { detailError = error.localizedDescription }
  }

  @ViewBuilder private func footer(_ inspection: ApplicationUninstall.Inspection, app: ApplicationInventory.Installed) -> some View {
    let choices = inspection.rows.filter { selected.contains($0.id) }
    let targets = choices.compactMap(\.target)
    let bundle = targets.first { $0.path.path == app.id }
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(ReviewLanguage.format("%lld selected · %@", Int64(targets.count),
          byteLabel(choices.reduce(0) { $0 + $1.action.bytes }))).monospacedDigit()
          .help("Estimated space after emptying Trash")
        Text("Selected files will be moved to the Trash.").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Remove", role: .destructive) {
        guard let bundle, let inspectedInventory, inspection.blocker == nil else { return }
        scan.cleanup.removeApplication([bundle] + targets.filter { $0.id != bundle.id },
          inventoryID: inspectedInventory, scan: scan)
      }
      .workspaceButton(.destructive)
      .disabled(bundle == nil || inspection.blocker != nil || scan.cleanup.busy || inspectedInventory != scan.inventoryID)
    }
  }
}
