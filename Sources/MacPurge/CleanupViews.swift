import SwiftUI

@MainActor @Observable final class CleanupSession {
  private(set) var busy = false
  private(set) var applying = false
  private(set) var restoring = false
  var preview: TrashPlan?
  private(set) var outcome: TrashOutcome?
  private(set) var receipts: [TrashReceipt] = []
  private(set) var message: String?
  @ObservationIgnored private var work: Task<Void, Never>?

  func refresh() async {
    do { receipts = try await CacheTrash.shared.available() } catch {
      message =
        ReviewLanguage.text("Geri alma kayıtları okunamadı.") + " " + error.localizedDescription
    }
  }

  func prepare(_ items: [ReportItem], scan: LiveScan) {
    guard !busy, scan.phase == .finished, let report = scan.report, !items.isEmpty else { return }
    busy = true
    message = nil
    work = Task {
      let plan = await CacheTrash.shared.prepare(
        items: items, reportID: report.id, projects: scan.projects)
      if !Task.isCancelled { preview = plan }
      busy = false
      work = nil
    }
  }

  func apply(_ plan: TrashPlan, scan: LiveScan) {
    guard !busy, !plan.targets.isEmpty, scan.phase == .finished,
      scan.report?.id == plan.reportID, preview?.id == plan.id
    else {
      message = ReviewLanguage.text("Tarama değişti. Önizlemeyi yeniden aç.")
      preview = nil
      return
    }
    preview = nil
    busy = true
    applying = true
    message = nil
    work = Task {
      let result = await CacheTrash.shared.apply(plan)
      outcome = result
      await refresh()
      busy = false
      applying = false
      work = nil
      scan.start()
    }
  }

  func cancel() { work?.cancel() }

  func restore(_ receipt: TrashReceipt, scan: LiveScan) {
    guard !busy else { return }
    busy = true
    restoring = true
    message = nil
    Task {
      do {
        try await CacheTrash.shared.restore(receipt.id)
        message = ReviewLanguage.text("Geri alındı") + " · " + receipt.original.path
      } catch {
        message = ReviewLanguage.text("Geri alınamadı") + " · " + error.localizedDescription
      }
      await refresh()
      busy = false
      restoring = false
      scan.start()
    }
  }
}

struct CleanupControls: View {
  let scan: LiveScan
  let choices: [ReportItem]
  let reportID: UUID
  @Binding var selected: Set<String>

  var body: some View {
    @Bindable var session = scan.cleanup
    VStack(alignment: .leading, spacing: 14) {
      Button {
        session.prepare(choices, scan: scan)
      } label: {
        Label("Çöp’e taşımayı incele…", systemImage: "trash")
      }
      .buttonStyle(.borderedProminent)
      .disabled(choices.isEmpty || scan.phase != .finished || session.busy)
      if session.busy {
        HStack {
          ProgressView().controlSize(.small)
          if session.restoring {
            Text("Geri alınıyor…")
          } else {
            Text(
              ReviewLanguage.text(
                session.applying ? "Çöp’e taşınıyor…" : "Önbellekler doğrulanıyor…"))
            Button("Durdur") { session.cancel() }
          }
        }
      }
      if let message = session.message { Text(message).font(.callout).textSelection(.enabled) }
      if let result = session.outcome {
        SectionHead(title: "Son işlem")
        Text(
          "Çöp’e taşınan: \(result.moved.count) klasör · \(byteLabel(result.moved.reduce(0) { $0 + $1.bytes }))"
        )
        if let delta = result.freeChange {
          Text(
            "Diskte gözlenen boş alan değişimi: \(delta < 0 ? "−" : "+")\(byteLabel(abs(delta)))"
          )
          .font(.callout)
        }
        ForEach(Array(result.notices.enumerated()), id: \.offset) { _, note in
          Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      if !session.receipts.isEmpty {
        SectionHead(title: "Çöp’ten geri al")
        ForEach(session.receipts) { receipt in
          Surface {
            HStack {
              Text(receipt.original.path).font(.caption).textSelection(.enabled)
              Spacer()
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([
                  CacheTrash.userTrash.appending(path: receipt.trashName)
                ])
              } label: {
                Image(systemName: "magnifyingglass")
              }.help("Çöp’te göster")
              Button("Geri al") { session.restore(receipt, scan: scan) }.disabled(session.busy)
            }.padding(12)
          }
        }
      }
    }
    .onChange(of: session.outcome?.id) {
      if let result = session.outcome { selected.subtract(result.completedItems) }
    }
    .task { await session.refresh() }
    .sheet(item: $session.preview) { plan in
      VStack(alignment: .leading, spacing: 14) {
        Text("Çöp’e taşıma önizlemesi").font(.title2.bold())
        Text(
          "Yalnızca aşağıdaki klasörler taşınır. Çöp aynı diskte yer kaplar. Geri almak için Alan planı’nı aç."
        )
        .font(.callout)
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.targets) { target in
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(target.name).bold()
                  Spacer()
                  Text(byteLabel(target.snapshot.bytes))
                }
                Text(target.path.path).font(.caption).foregroundStyle(.secondary).textSelection(
                  .enabled)
              }
              Divider()
            }
            ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, note in
              Label(note, systemImage: "exclamationmark.circle").font(.caption)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
          Text(
            "\(plan.targets.count) klasör · \(byteLabel(plan.targets.reduce(0) { $0 + $1.snapshot.bytes }))"
          )
          Spacer()
          Button("Vazgeç") { session.preview = nil }.keyboardShortcut(.cancelAction)
          Button("Çöp’e taşı", role: .destructive) { session.apply(plan, scan: scan) }
            .disabled(plan.targets.isEmpty || reportID != plan.reportID || scan.phase != .finished)
        }
      }.padding(20).frame(minWidth: 480, idealWidth: 580, minHeight: 280, idealHeight: 400)
    }
  }
}
