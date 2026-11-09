import SwiftUI

@MainActor @Observable final class DockerSession {
  private let manager: DockerManager
  private(set) var overview: DockerOverview?
  private(set) var busy = false
  private(set) var error: String?
  private(set) var result: DockerActionReceipt?
  var preview: DockerPreview?
  init(manager: DockerManager = .local()) { self.manager = manager }

  func refresh() async {
    guard !busy else { return }
    busy = true; error = nil
    defer { busy = false }
    do { overview = try await manager.overview() } catch { self.error = error.localizedDescription }
  }
  func prepare(_ operation: DockerOperation) async {
    guard !busy else { return }
    busy = true; error = nil
    defer { busy = false }
    do { preview = try await manager.preview(operation) } catch { self.error = error.localizedDescription }
  }
  func discard(_ id: UUID) async { preview = nil; await manager.discard(id) }
  func confirm(_ id: UUID, acknowledged: Bool) async {
    guard !busy else { return }
    busy = true; preview = nil; error = nil
    defer { busy = false }
    do { result = try await manager.execute(id: id, acknowledged: acknowledged) }
    catch { self.error = error.localizedDescription }
    do { overview = try await manager.overview() } catch { self.error = self.error ?? error.localizedDescription }
  }
}

struct DockerView: View {
  let contentInset: CGFloat
  var query = ""
  @State private var session = DockerSession()
  @State private var kind = DockerItem.Kind.image
  @State private var selection: String?
  @State private var inspecting: DockerItem?
  @State private var acknowledged = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      WorkspaceListBar {
        VStack(alignment: .leading, spacing: 8) {
          Text("Docker reports storage inside its virtual machine. Reclaimed space may take time to return to macOS.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            WorkspaceTabs(label: "Docker data", choices: [.image, .container, .volume, .cache], selection: $kind) { kind in
              switch kind {
              case .image: Text("Images")
              case .container: Text("Containers")
              case .volume: Text("Volumes")
              case .cache: Text("Build cache")
              }
            }
            Button("Refresh Docker") { Task { await session.refresh() } }
              .workspaceButton(.secondary)
              .disabled(session.busy)
            if session.busy && session.overview != nil {
              WorkspaceActivityIndicator(label: "Kontrol ediliyor…")
            }
          }
        }
      }
      if session.overview == nil && session.error == nil {
        WorkspaceSkeleton(layout: .table, message: "Kontrol ediliyor…", rows: 7)
          .padding(.horizontal, contentInset)
          .padding(.top, contentInset)
          .frame(maxHeight: .infinity, alignment: .top)
      } else {
        let rows = session.overview?.items.filter { $0.kind == kind
          && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.objectID.localizedCaseInsensitiveContains(query)) } ?? []
        Table(rows, selection: $selection) {
          TableColumn("Öğe") { item in Text(item.name).lineLimit(1).truncationMode(.middle).help(item.detail) }
            .width(min: 160, ideal: 260)
          TableColumn("Etiket") { item in Text(ReviewLanguage.text("İncele")).font(.caption) }
            .width(min: 60, ideal: 80)
          TableColumn("Boyut") { item in Text(item.bytes.map(byteLabel) ?? "—").monospacedDigit() }
            .width(min: 75, ideal: 95).alignment(.trailing)
          TableColumn("Unique data") { item in Text(item.uniqueBytes.map(byteLabel) ?? "—").monospacedDigit() }
            .width(min: 75, ideal: 105).alignment(.trailing)
          TableColumn("İşlem") { item in
            if let operation = item.operation {
              Button { acknowledged = false; Task { await session.prepare(operation) } } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).disabled(session.busy).help(ReviewLanguage.text("Review Docker removal…"))
                .accessibilityLabel(ReviewLanguage.text("Review Docker removal…") + " · " + item.name)
            } else {
              Button { inspecting = item } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).help(ReviewLanguage.text(item.warning))
                .accessibilityLabel(ReviewLanguage.text("Ayrıntılar") + " · " + item.name)
            }
          }.width(54)
        }
        .storageTableScroller(contentInset: 0)
        .contextMenu(forSelectionType: String.self) { ids in
          if let item = rows.first(where: { ids.contains($0.id) }) {
            Button("Ayrıntılar") { inspecting = item }
          }
        } primaryAction: { ids in
          inspecting = rows.first { ids.contains($0.id) }
        }
        .padding(.horizontal, contentInset)
        .padding(.top, contentInset)
      }
      if session.error != nil || session.result != nil {
        WorkspaceListBar {
          VStack(alignment: .leading, spacing: 4) {
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let result = session.result {
              Text(ReviewLanguage.format("Docker operation completed: %@", result.object)).font(.callout)
              if let bytes = result.reclaimedBytes {
                Text(ReviewLanguage.format("Docker reports reclaimed: %@", byteLabel(bytes))).font(.caption)
              }
            }
          }
        }
      }
    }.task { await session.refresh() }
    .popover(item: $inspecting) { item in
      VStack(alignment: .leading, spacing: 10) {
        Text(item.name).font(.headline)
        Text(item.objectID).font(.caption.monospaced()).textSelection(.enabled)
        Text(item.detail).font(.caption).textSelection(.enabled)
        Text(ReviewLanguage.text(item.warning)).font(.callout)
        if !item.references.isEmpty {
          Text(item.references.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
        }
      }.padding(18).frame(width: 380)
    }
    .sheet(item: $session.preview) { plan in
      VStack(alignment: .leading, spacing: 14) {
        Text("Review Docker removal").font(.title2.bold())
        InventoryList([plan.item]) { item in
          InventoryReadout(title: item.name, amount: item.uniqueBytes.map(byteLabel) ?? "—", symbol: "shippingbox",
            subtitle: item.objectID)
        }
        Text(ReviewLanguage.text(plan.item.warning))
        Text("This is a permanent Docker operation. It cannot be restored from the Trash.")
          .font(.callout).foregroundStyle(.secondary)
        Text(plan.request.display).font(.caption.monospaced()).textSelection(.enabled)
        Toggle("Belirtilen riskleri okudum ve kabul ediyorum.", isOn: $acknowledged).toggleStyle(.checkbox)
        HStack {
          Spacer()
          Button("Vazgeç") { Task { await session.discard(plan.id) } }
            .workspaceButton(.secondary)
            .keyboardShortcut(.cancelAction)
          Button("Permanently remove Docker item", role: .destructive) {
            Task { await session.confirm(plan.id, acknowledged: acknowledged) }
          }
          .workspaceButton(.destructive)
          .disabled(!acknowledged || session.busy)
        }
      }.padding(22).frame(width: 560)
    }
  }
}
