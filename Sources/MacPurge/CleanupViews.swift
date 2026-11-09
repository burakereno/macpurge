import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

@MainActor @Observable final class CleanupSession {
  let engine: CacheTrash
  private let eraseSystemLogs: @Sendable () async throws -> Void
  var permanentReview: PermanentCleanupReview?
  init(engine: CacheTrash = .shared,
       eraseSystemLogs: @escaping @Sendable () async throws -> Void = SystemLogStore.erase) {
    self.engine = engine
    self.eraseSystemLogs = eraseSystemLogs
  }

  func reviewPermanentCleanup(_ item: ReportItem, scan: LiveScan) {
    guard !busy, preview == nil, permanentReview == nil, let report = scan.report,
      let operation = scan.action(for: item).permanentOperation, report.items.contains(item)
    else { return }
    permanentReview = PermanentCleanupReview(reportID: report.id, itemID: item.id, operation: operation)
  }

  func confirmPermanentCleanup(_ review: PermanentCleanupReview, scan: LiveScan) {
    guard review === permanentReview, !busy, preview == nil, review.stage == .confirmation else { return }
    guard scan.phase == .finished, let report = scan.report, report.id == review.reportID,
      let row = report.items.first(where: { $0.id == review.itemID }) else {
      review.finish(ReviewLanguage.text(review.operation == .systemLogs
        ? "The scan changed. Review the system logs again." : "The scan changed. Review the simulator again."))
      return
    }
    let decision = scan.action(for: row)
    guard decision.permanentOperation == review.operation else {
      review.finish(decision.availability.explanation ?? ReviewLanguage.text("Review this item again."))
      return
    }
    guard review.beginClearing() else { return }
    busy = true
    work = Task {
      defer { busy = false; work = nil }
      do {
        switch review.operation {
        case .systemLogs:
          try await eraseSystemLogs()
          await scan.refreshSystemLogs()
          review.finish(ReviewLanguage.text("System logs were cleared. macOS continues to record new entries."))
        case .simulator(let device):
          try await engine.eraseSimulator(device, row: row, projects: scan.protectedProjects)
          await scan.refreshAfterSimulatorErase(row)
          review.finish(ReviewLanguage.format("%@ was reset to factory settings.", device.name))
        }
      } catch {
        if case .simulator = review.operation {
          await scan.refreshMoveStates(only: [row.id])
          review.finish(ReviewLanguage.text("Simulator erase did not complete.") + " " + error.localizedDescription)
        } else if error is CancellationError {
          review.finish(ReviewLanguage.text("Authorization was cancelled."))
        } else {
          review.finish(ReviewLanguage.text("macOS could not confirm that the logs were cleared.") + " " + error.localizedDescription)
        }
      }
    }
  }
  private(set) var busy = false
  private(set) var applying = false
  private(set) var restoring = false
  var preview: TrashPlan?
  private(set) var outcome: TrashOutcome?
  private(set) var receipts: [TrashReceipt] = []
  private(set) var message: String?
  @ObservationIgnored private var work: Task<Void, Never>?

  func refresh() async {
    do { receipts = try await engine.available() } catch {
      message =
        ReviewLanguage.text("Geri alma kayıtları okunamadı.") + " " + error.localizedDescription
    }
  }

  func beginExternalOperation() -> Bool {
    guard !busy, preview == nil, permanentReview == nil else { return false }
    busy = true
    return true
  }
  func endExternalOperation() { busy = false }

  func prepare(
    _ items: [ReportItem], scan: LiveScan, onlyPath: URL? = nil, explicit: Bool = false,
    includeSkipped: Bool = false
  )
  {
    guard !busy, preview == nil, permanentReview == nil, scan.phase == .finished, let report = scan.report else { return }
    let requested = Set(items.map(\.id))
    let candidates =
      explicit
      ? scan.explicitSelection(requested, in: report)
      : report.movableItems(requested, states: scan.moveStates, hidden: scan.hiddenIDs)
    guard !candidates.isEmpty else { return }
    let skipped = includeSkipped ? items.compactMap { item in
      scan.listMoveState(item).explanation.map { item.actionTitle + " · " + $0 }
    } : []
    busy = true
    message = nil
    work = Task {
      var plan = await engine.prepare(
        items: candidates, reportID: report.id, projects: scan.protectedProjects, onlyPath: onlyPath,
        manual: explicit ? scan.manualMoves : [:])
      if !plan.skipped.isEmpty, !Task.isCancelled {
        let missing = requested.subtracting(plan.targets.map(\.itemID))
        if !missing.isEmpty { await scan.refreshMoveStates(only: missing) }
      }
      plan.skipped += skipped
      if !Task.isCancelled { preview = plan }
      busy = false
      work = nil
    }
  }

  func confirmMove(_ id: UUID, scan: LiveScan, acknowledgedReview: Bool = false) {
    guard !busy, preview?.id == id else { return }
    guard
      let confirmed = ConfirmedTrashPlan(
        confirming: id, preview: &preview,
        currentReportID: scan.phase == .finished ? scan.report?.id : nil,
        acknowledgedReview: acknowledgedReview)
    else {
      message = ReviewLanguage.text("Tarama değişti. Önizlemeyi yeniden aç.")
      preview = nil
      return
    }
    applyMove(confirmed, scan: scan)
  }

  func removeApplication(_ targets: [TrashTarget], inventoryID: UUID, scan: LiveScan) {
    guard !busy, preview == nil, permanentReview == nil, scan.inventoryID == inventoryID,
      let confirmed = ConfirmedTrashPlan(removingApplication: TrashPlan(reportID: inventoryID,
        projects: scan.protectedProjects, targets: targets, exclusions: scan.excludedFolders))
    else { return }
    applyMove(confirmed, scan: scan)
  }

  private func applyMove(_ confirmed: ConfirmedTrashPlan, scan: LiveScan) {
    busy = true
    applying = true
    message = nil
    let restartStorageScan = confirmed.plan.applicationUninstall != nil && scan.phase == .running
    if restartStorageScan { scan.cancel() }
    work = Task {
      if confirmed.plan.applicationUninstall != nil { await scan.finishCurrentScan() }
      let result = await engine.apply(confirmed)
      outcome = result
      // Stop cancels remaining moves, never the reconciliation of completed renames.
      await Task {
        await scan.refreshAfterCleanup(result.moved, restored: false, disk: result.diskAfter)
      }.value
      if scan.historyEnabled {
        do {
          try await HistoryIO.shared.remember(MovedFolder.from(result, plan: confirmed.plan))
        } catch {
          message = error.localizedDescription
        }
      }
      await refresh()
      busy = false
      applying = false
      work = nil
      if restartStorageScan { scan.start() }
    }
  }

  func cancel() { if permanentReview?.stage != .clearing { work?.cancel() } }
  func finishCurrentOperation() async { await work?.value }

  func restore(_ receipt: TrashReceipt, scan: LiveScan) {
    guard !busy, permanentReview == nil else { return }
    busy = true
    restoring = true
    message = nil
    work = Task {
      do {
        // An already requested scan must not publish stale results over the restoration.
        await scan.finishCurrentScan()
        try Task.checkCancellation()
        let receipt = try await engine.restore(receipt.id)
        await Task {
          await scan.refreshAfterCleanup(
            [receipt], restored: true, disk: await engine.diskReading())
        }.value
        message = ReviewLanguage.text("Geri alındı") + " · " + receipt.original.path
        do { try await scan.forgetRegrowth(at: receipt.original.path) } catch {
          message = (message ?? "") + " · " + error.localizedDescription
        }
      } catch {
        message = ReviewLanguage.text("Geri alınamadı") + " · " + error.localizedDescription
      }
      await refresh()
      busy = false
      restoring = false
      work = nil
    }
  }
}

struct CleanupControls: View {
  let scan: LiveScan
  let choices: [ReportItem]

  var body: some View {
    @Bindable var session = scan.cleanup
    VStack(alignment: .leading, spacing: 14) {
      Button {
        session.prepare(choices, scan: scan, explicit: true)
      } label: {
        Label("Çöp’e taşımayı incele…", systemImage: "trash")
      }
      .workspaceButton()
      .disabled(choices.isEmpty || scan.phase != .finished || session.busy)
      if session.busy && session.permanentReview == nil {
        HStack {
          WorkspaceActivityIndicator()
          if session.restoring {
            Text("Geri alınıyor…")
          } else {
            Text(
              ReviewLanguage.text(
                session.applying ? "Çöp’e taşınıyor…" : "Seçilen klasörler doğrulanıyor…"))
            Button("Durdur") { session.cancel() }
              .workspaceButton(.secondary)
          }
        }
      }
      if let message = session.message { Text(message).font(.callout).textSelection(.enabled) }
      if let result = session.outcome {
        SectionHead(title: "Son işlem")
        Text(
          ReviewLanguage.format("Çöp’e taşınan: %lld öğe · %@", Int64(result.moved.count),
            ReviewLanguage.format("Tahmini kazanım: %@",
              byteLabel(result.moved.reduce(0) { $0 + $1.expectedRecoveryBytes })))
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
        InventoryList(session.receipts) { receipt in
          InventoryReadout(title: receipt.original.lastPathComponent,
            amount: receipt.reclaimableBytes.map(byteLabel) ?? "—",
            symbol: "trash", subtitle: receipt.original.path,
            location: CacheTrash.userTrash.appending(path: receipt.trashName),
            actionSymbol: "arrow.uturn.backward", actionHelp: "Geri al",
            action: { session.restore(receipt, scan: scan) }, disabled: session.busy)
        }
      }
    }
    .task { await session.refresh() }
  }
}

struct TrashPreviewSheet: View {
  let plan: TrashPlan
  let scan: LiveScan
  @State private var acknowledgedReview = false
  @State private var showsSkipped = false
  @State private var listHeight: CGFloat = 120

  private var total: String { byteLabel(plan.reclaimableBytes) }
  private var current: Bool { scan.phase == .finished && scan.report?.id == plan.reportID }
  private var canContinue: Bool {
    current && !plan.targets.isEmpty && (!plan.needsReview || acknowledgedReview)
  }

  var body: some View {
    let items = Dictionary(grouping: plan.targets, by: \.itemID).values.sorted {
      ($0[0].name, $0[0].id) < ($1[0].name, $1[0].id)
    }
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        SymbolTile(symbol: plan.targets.isEmpty ? "info.circle" : "trash", tint: Ink.sea)
        VStack(alignment: .leading, spacing: 3) {
          Text(ReviewLanguage.text(
            plan.targets.isEmpty ? "Taşınabilir öğe bulunamadı." : "Çöp’e taşıma önizlemesi")
          ).font(.title2.bold()).accessibilityAddTraits(.isHeader)
          if !plan.targets.isEmpty {
            Text("\(items.count) öğe · \(total)")
              .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !plan.targets.isEmpty {
            InventoryList(items, id: \.first?.itemID) { targets in
              if let first = targets.first {
                TrashPreviewRow(target: first, targets: targets,
                  item: scan.report?.items.first { $0.id == first.itemID })
              }
            }
          }
          ForEach(plan.coveredReviews, id: \.path) { review in
            Label(ReviewLanguage.text(review.title) + " · " + ReviewLanguage.text(review.warning),
              systemImage: "exclamationmark.triangle").font(.callout)
          }
          if !plan.skipped.isEmpty {
            if plan.targets.isEmpty {
              skippedReasons
            } else {
              DisclosureGroup(isExpanded: $showsSkipped) {
                skippedReasons.padding(.top, 5)
              } label: {
                Text("Taşınmayacak öğeler (\(plan.skipped.count))").font(.callout.weight(.medium))
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(listHeight, 300))

      if !plan.targets.isEmpty {
        Label {
          Text("Dosyalar Çöp boşaltılana kadar diskte yer kaplar. Alan planı’ndan geri alabilirsin.")
            .fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: "arrow.uturn.backward.circle") }
        .font(.callout).foregroundStyle(.secondary)
      }

      Divider()
      if plan.needsReview {
        Toggle("Belirtilen riskleri okudum ve kabul ediyorum.", isOn: $acknowledgedReview)
          .toggleStyle(.checkbox)
      }
      if !current {
        Text("Tarama değişti. Önizlemeyi yeniden aç.").font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button(plan.targets.isEmpty ? "Bitti" : "Vazgeç") { scan.cleanup.preview = nil }
          .workspaceButton(plan.targets.isEmpty ? .primary : .secondary)
          .keyboardShortcut(.cancelAction)
        if !plan.targets.isEmpty {
          Button("Çöp’e taşı", role: .destructive) {
            scan.cleanup.confirmMove(plan.id, scan: scan, acknowledgedReview: acknowledgedReview)
          }
          .workspaceButton(.destructive).disabled(!canContinue)
        }
      }
    }
    .padding(22).frame(width: 510).fixedSize(horizontal: false, vertical: true)
  }

  private var skippedReasons: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, note in
        Label(note, systemImage: "info.circle").font(.callout)
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct TrashPreviewRow: View {
  let target: TrashTarget
  let targets: [TrashTarget]
  let item: ReportItem?
  @State private var showsLocations = false
  @State private var showsExplanation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(target.name).font(.headline).lineLimit(1).truncationMode(.middle).help(target.name)
        SafetyBadge(level: target.review?.profile.assessment(for: .complete)?.level ?? .safe).fixedSize()
        Spacer(minLength: 6)
        InventoryAmount(text: byteLabel(targets.reduce(0) { $0 + $1.snapshot.reclaimableBytes }), prominent: true)
      }
      if targets.count == 1 {
        pathLabel(target)
      } else {
        DisclosureGroup(isExpanded: $showsLocations) {
          InventoryRows(targets) { target in
            InventoryReadout(title: target.path.lastPathComponent,
              amount: byteLabel(target.snapshot.reclaimableBytes), subtitle: target.path.path,
              location: target.path)
          }
        } label: { Text("\(targets.count) konum").font(.caption) }
      }
      if let workspace = target.workspace {
        Text(verbatim: workspace).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        Text("Xcode ara çıktıları yeniden üretir. Sonraki derleme daha uzun sürebilir.")
          .font(.callout).foregroundStyle(.secondary)
      }
      if let review = target.review {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text(ReviewLanguage.text(review.warning)).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 3)
      }
      if let item {
        DisclosureGroup(ReviewLanguage.text("Why review it?"), isExpanded: $showsExplanation) {
          InventoryExplanationView(item: item)
        }.font(.caption)
      }
    }.padding(.horizontal, InventoryLayout.horizontalPadding)
      .padding(.vertical, InventoryLayout.verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .inventoryRowDetails()
      .inventoryRowCard(isExpanded: showsLocations || showsExplanation)
  }

  private func pathLabel(_ target: TrashTarget) -> some View {
    Text(verbatim: target.path.path).font(.caption).foregroundStyle(.secondary)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
  }
}

struct RowMoveButton: View {
  let title: String
  let reason: String?
  let busy: Bool
  var readyHelp = ReviewLanguage.text("Çöp’e taşımayı incele…")
  let action: () -> Void
  @State private var showingReason = false

  var body: some View {
    Button {
      if reason != nil { showingReason = true } else { action() }
    } label: {
      Image(systemName: reason == nil ? "trash" : "info.circle")
        .font(.system(size: 13)).foregroundStyle(.secondary)
        .frame(width: InventoryLayout.actionWidth, height: 26).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(reason == nil && busy)
    .help(reason ?? (busy ? ReviewLanguage.text("Önce devam eden işlemin bitmesini bekle.") : readyHelp))
    .accessibilityLabel(
      ReviewLanguage.text(reason == nil ? "Çöp’e taşı…" : "Neden taşınamıyor?") + " · " + title)
    .popover(isPresented: $showingReason) {
      if let reason {
        VStack(alignment: .leading, spacing: 6) {
          Text(title).font(.headline)
          Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(width: 280, alignment: .leading)
      }
    }
    .onChange(of: reason) { showingReason = false }
  }
}

/// The same action is used for measured rows, inspector details and project outputs.
struct ItemTrashButton: View {
  let scan: LiveScan
  let item: ReportItem
  var onlyPath: URL? = nil
  var showActionTitle = false
  var beforePreview: (() -> Void)? = nil

  var body: some View {
    if !scan.hiddenIDs.contains(item.id) {
      if let operation = scan.action(for: item).permanentOperation {
        let label = operation.title + "…"
        let button = Button {
          if let beforePreview { beforePreview() } else { scan.cleanup.reviewPermanentCleanup(item, scan: scan) }
        } label: {
          if showActionTitle {
            Label(label, systemImage: "eraser")
          } else {
            Image(systemName: "eraser").frame(width: InventoryLayout.actionWidth, height: 26)
              .contentShape(Rectangle())
          }
        }
        .help(label).accessibilityLabel(label + " · " + item.actionTitle)
        .disabled(scan.cleanup.busy)
        if showActionTitle {
          button.workspaceButton(.secondary)
        } else {
          button.buttonStyle(.plain).foregroundStyle(.secondary)
        }
      } else {
        RowMoveButton(title: item.actionTitle, reason: scan.listMoveState(item).explanation, busy: scan.cleanup.busy) {
          if let beforePreview {
            beforePreview()
          } else {
            scan.cleanup.prepare([item], scan: scan, onlyPath: onlyPath, explicit: true)
          }
        }
      }
    }
  }
}

struct CategoryMoveButton: View {
  let scan: LiveScan
  let group: ScanGroup
  let items: [ReportItem]
  let eligible: Int

  private var reason: String? {
    guard eligible == 0 else { return nil }
    if group == .simulators, items.contains(where: { scan.action(for: $0).permanentOperation != nil }) {
      return ReviewLanguage.text("Choose a device data row to erase one simulator.")
    }
    let reasons = Set(items.compactMap { scan.listMoveState($0).explanation })
    if reasons.count == 1 { return reasons.first }
    if items.isEmpty { return scan.listMoveState(nil).explanation }
    return ReviewLanguage.text("Bu kategoride taşınabilir öğe yok. Ayrıntı için satırdaki bilgi düğmesini aç.")
  }

  var body: some View {
    if eligible == 0, let log = items.first(where: { scan.action(for: $0).permanentOperation == .systemLogs }) {
      ItemTrashButton(scan: scan, item: log)
    } else {
      RowMoveButton(
        title: ReviewLanguage.text(group.titleKey), reason: reason, busy: scan.cleanup.busy,
        readyHelp: String(
          format: ReviewLanguage.text("Taşınabilir öğeler: %lld / %lld"), eligible, items.count)
      ) {
        scan.cleanup.prepare(items.filter { scan.action(for: $0).permanentOperation == nil },
          scan: scan, explicit: true, includeSkipped: true)
      }
    }
  }
}

struct SafeTrashButton: View {
  let scan: LiveScan
  var group: ScanGroup? = nil
  let items: [ReportItem]
  var alwaysVisible = false

  var body: some View {
    if alwaysVisible || !items.isEmpty {
      let ready = scan.safeMoves(items)
      let available = scan.phase == .finished && !ready.isEmpty
      let total = scan.cleanupBytes(ready)
      let actionTitle = ReviewLanguage.text("Güvenlileri temizle…")
        + (available ? " · " + byteLabel(total) : "")
      let title = (group.map { ReviewLanguage.text($0.titleKey) + " · " } ?? "")
        + actionTitle
      MainAction(title: actionTitle, symbol: "trash") {
        scan.cleanup.prepare(ready, scan: scan)
      }
      .monospacedDigit()
      .disabled(!available || scan.cleanup.busy)
      .accessibilityLabel(title)
      .help(scan.cleanup.busy ? ReviewLanguage.text("Önce devam eden işlemin bitmesini bekle.")
        : helpText(hasReadyItems: !ready.isEmpty))
    }
  }

  private func helpText(hasReadyItems: Bool) -> String {
    if scan.phase != .finished { return ReviewLanguage.text("Ölçüm bekleniyor") }
    if scan.actions.isEmpty { return ReviewLanguage.text("Kontrol ediliyor…") }
    return ReviewLanguage.text(
      hasReadyItems ? "Çöp’e taşımayı incele…" : "Taşınabilir öğe bulunamadı.")
  }
}
