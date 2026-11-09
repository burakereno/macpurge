import AppKit
import Darwin
import Observation
import WidgetKit

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum ScanPhase: Equatable {
  case idle, running, cancelled, finished

  var awaitsMeasurements: Bool { self == .idle || self == .running }
}

enum ScanProgressStage {
  case discovering
  case measuring(title: String, start: Int, total: Int)
  case finishing
}

@MainActor @Observable final class LiveScan {
  let cleanup: CleanupSession
  private nonisolated static let preference = "liveScan.selectedProjectPaths"
  private let defaults: UserDefaults
  private let home: URL
  private let localInventory: @Sendable (URL, Bool, [URL], ScanVolumes) async throws -> [ScanRoot]
  private let toolInventory: @Sendable (URL, SimulatorInventory) async throws -> [ScanRoot]
  let recordsHistory: Bool
  private(set) var excludedFolders: [URL]
  private(set) var historyRetention: ActivityRetention
  private(set) var projects: [URL]
  private(set) var roots: [ScanRoot] = []
  private(set) var overviewCategories: [ScanGroup: OverviewCategory] = [:]
  private(set) var results: [String: RootSize] = [:]
  private(set) var groupBytes: [ScanGroup: Int64] = [:]
  private(set) var activeRoot: ScanRoot?
  private(set) var phase: ScanPhase = .idle
  private(set) var progressStage: ScanProgressStage = .discovering
  private(set) var measuredAt: Date?
  private(set) var report: ScanReport?
  private var storageScope: String?
  private var storagePreview: ScanReport?
  @ObservationIgnored private var completedRoots:
    (scope: String, roots: [ScanRoot], results: [String: RootSize])?
  var storageReport: ScanReport? {
    if phase == .running { return storagePreview }
    if phase == .cancelled { return lastStorageReport(in: storageScope) }
    return report
  }
  private func lastStorageReport(in scope: String?) -> ScanReport? {
    guard let scope else { return nil }
    return report?.scope == scope ? report : history.first { $0.scope == scope }
  }
  private(set) var pendingCategories = Set<ScanGroup>()
  private(set) var history: [ScanReport] = []
  private(set) var regrownFolders: [RegrownFolder]?
  private(set) var historyEnabled: Bool
  private(set) var detailed = true
  private(set) var historyError: String?
  @ObservationIgnored private var loadedHistory = false
  private(set) var volume: VolumeReading?
  private(set) var volumeDevice: Int32?
  private(set) var simulatorInventory: SimulatorInventory?
  private(set) var projectDiscovery = ProjectDiscovery()
  var protectedProjects: [URL] {
    Array(Set(projects + projectDiscovery.projects))
  }
  private(set) var projectArtifacts: [ProjectArtifact] = []
  private(set) var hiddenIDs: Set<String>
  private(set) var selectionNote: String?
  @ObservationIgnored private var work: Task<Void, Never>?
  private var generation = UUID()
  var inventoryID: UUID { generation }
  private(set) var actions: [String: CleanupAction] = [:]
  private var previousActions: [String: CleanupAction] = [:]
  var moveStates: [String: MoveAvailability] { actions.mapValues(\.availability) }
  private(set) var manualMoves: [String: ManualReview] = [:]
  private var reviewRestrictions: [String: String] = [:]

  func action(for item: ReportItem?) -> CleanupAction {
    guard phase == .finished else { return .unavailable(.blocked(ReviewLanguage.text("Ölçüm bekleniyor"))) }
    guard let item, !hiddenIDs.contains(item.id) else {
      return .measurement(ReviewLanguage.text("Taşınabilir öğe bulunamadı."))
    }
    return actions[item.id] ?? .unavailable(.blocked(ReviewLanguage.text("Kontrol ediliyor…")))
  }

  func listMoveState(_ item: ReportItem?) -> MoveAvailability { action(for: item).availability }

  func wasCleanupCandidate(_ item: ReportItem) -> Bool {
    if phase == .finished { return listMoveState(item) == .ready }
    return previousActions[item.id]?.availability == .ready
  }

  // Keep filtered rows visible while remeasuring, but never authorize from the prior scan.
  func filterRisk(for item: ReportItem) -> SafetyLevel? {
    if let decision = actions[item.id] ?? previousActions[item.id] { return decision.safety(for: item) }
    return item.safety.flatMap(SafetyLevel.init(rawValue:))
  }

  func explicitSelection(_ ids: Set<String>, in report: ScanReport) -> [ReportItem] {
    report.items.filter { ids.contains($0.id) && listMoveState($0) == .ready }
  }

  func distinctMoves(_ items: [ReportItem]) -> [ReportItem] {
    let eligible = items.filter { listMoveState($0) == .ready }
    // Only a whole physical move covers descendants. Simulator cache rows are a set
    // of precise cache boundaries, not an authorization to move the device root.
    let parents = Set(eligible.filter { $0.category != ScanGroup.simulators.rawValue }.map(\.path))
    var seen = Set<String>()
    return eligible.filter { item in
      if item.category == ScanGroup.simulators.rawValue && parents.contains(item.path) { return false }
      guard seen.insert(item.path).inserted else { return false }
      var path = item.path[...]
      while let slash = path.lastIndex(of: "/") {
        path = path[..<slash]
        if parents.contains(String(path)) { return false }
      }
      return true
    }
  }

  /// Filter the full inventory before limiting previews: a large measured-only row must
  /// never displace a smaller actionable row.
  var overviewCandidates: [ReportItem] {
    guard phase == .finished, let report else { return [] }
    return report.items.filter { action(for: $0).bytes > 0 }.sorted { lhs, rhs in
      let a = actions[lhs.id]?.bytes ?? 0
      let b = actions[rhs.id]?.bytes ?? 0
      return a == b ? lhs.id < rhs.id : a > b
    }
  }

  func distinctCleanups(_ items: [ReportItem]) -> [ReportItem] {
    let moves = Set(distinctMoves(items).map(\.id))
    var seen = Set<String>()
    return items.filter {
      (moves.contains($0.id) || action(for: $0).permanentOperation != nil) && seen.insert($0.id).inserted
    }
  }

  func safeMoves(_ items: [ReportItem]) -> [ReportItem] {
    distinctMoves(items.filter { !hiddenIDs.contains($0.id) && action(for: $0).risk == .safe })
  }

  func cleanupBytes(_ items: [ReportItem]) -> Int64 {
    distinctCleanups(items.filter { !hiddenIDs.contains($0.id) })
      .reduce(0) { $0 + action(for: $1).bytes }
  }

  func actionDescription(_ item: ReportItem) -> String {
    if let operation = action(for: item).permanentOperation { return operation.warning }
    return ReviewLanguage.text(manualMoves[item.id]?.warning ?? item.reason)
  }

  func selectionLabel(_ rows: [ReportItem]) -> String {
    String(format: ReviewLanguage.text("%lld öğe · %@"), Int64(rows.count),
      byteLabel(cleanupBytes(rows)))
  }

  func categorySelectionLabel(_ eligible: [ReportItem]) -> String {
    if phase != .finished || (actions.isEmpty && report?.items.isEmpty == false) {
      return ReviewLanguage.text("Ölçüm bekleniyor")
    }
    return String(format: ReviewLanguage.text("Şu anda taşınabilir: %lld öğe · %@"),
      Int64(eligible.count), byteLabel(cleanupBytes(eligible)))
  }

  var cleanupReadings: [String: DirectoryReading] {
    results.values.reduce(into: [:]) { $0.merge($1.cleanupReadings) { a, _ in a } }
  }

  func refreshMoveStates(only ids: Set<String>? = nil) async {
    guard phase == .finished, let report else { return }
    let token = generation
    let rows = ids.map { ids in report.items.filter { ids.contains($0.id) } } ?? report.items
    guard
      let states = try? await cleanup.engine.actions(
        for: rows, projects: protectedProjects, reportID: token, readings: cleanupReadings,
        manual: manualMoves, restrictions: reviewRestrictions),
      !Task.isCancelled, phase == .finished, generation == token, let current = self.report
    else { return }
    if current.id == report.id && ids == nil {
      actions = states
      previousActions = [:]
    } else {
      // A targeted update may finish while a foreground eligibility check is suspended.
      let unchanged = Set(rows).intersection(current.items)
      for item in unchanged { actions[item.id] = states[item.id] }
    }
  }

  init(
    defaults: UserDefaults = .standard, recordsHistory: Bool = true,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    cleanupEngine: CacheTrash = .shared,
    eraseSystemLogs: @escaping @Sendable () async throws -> Void = SystemLogStore.erase,
    localInventory: @escaping @Sendable (URL, Bool, [URL], ScanVolumes) async throws -> [ScanRoot] =
      ExtendedInventory.discover,
    toolInventory: @escaping @Sendable (URL, SimulatorInventory) async throws -> [ScanRoot] =
      ExtendedInventory.toolReports
  ) {
    self.home = home
    self.cleanup = CleanupSession(engine: cleanupEngine, eraseSystemLogs: eraseSystemLogs)
    self.localInventory = localInventory
    self.toolInventory = toolInventory
    self.defaults = defaults
    self.recordsHistory = recordsHistory
    hiddenIDs = Set(defaults.stringArray(forKey: "hiddenRows") ?? [])
    historyEnabled =
      recordsHistory
      && (defaults.object(forKey: "keepsScanArchive") == nil
        || defaults.bool(forKey: "keepsScanArchive"))
    projects = Self.selectedProjects(defaults: defaults)
    excludedFolders = ScanExclusions.saved(in: defaults).paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    historyRetention = ActivityRetention.saved(in: defaults)
  }

  nonisolated static func selectedProjects(defaults: UserDefaults = .standard) -> [URL] {
    (defaults.stringArray(forKey: Self.preference) ?? []).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
  }
  func hide(_ item: ReportItem) {
    hiddenIDs.insert(item.id)
    defaults.set(Array(hiddenIDs), forKey: "hiddenRows")
  }
  func restoreHidden() {
    hiddenIDs = []
    defaults.removeObject(forKey: "hiddenRows")
  }

  func startDetailed() {
    guard !cleanup.busy else { return }
    detailed = true
    start()
  }
  func startQuick() {
    guard !cleanup.busy else { return }
    detailed = false
    start()
  }
  func finishCurrentScan() async { await work?.value }

  func refreshAfterCleanup(_ receipts: [TrashReceipt], restored: Bool, disk: VolumeReading?) async {
    guard !receipts.isEmpty else { return }
    await refreshMeasurements(receipts, restored: restored, disk: disk)
  }

  func refreshSystemLogs() async {
    await refreshMeasurements([], restored: false, disk: await cleanup.engine.diskReading(),
      remeasurePaths: [SystemLogStore.path, SystemLogStore.textArchive])
  }

  func refreshAfterSimulatorErase(_ row: ReportItem) async {
    await refreshMeasurements([], restored: false, disk: await cleanup.engine.diskReading(),
      remeasurePaths: [row.path])
  }

  private func refreshMeasurements(_ receipts: [TrashReceipt], restored: Bool, disk: VolumeReading?,
    remeasurePaths: Set<String> = []) async {
    let token = generation
    do {
      let exclusions = ScanExclusions(paths: excludedFolders.map(\.path))
      let patch = try await ScanExclusions.$current.withValue(exclusions) { [self] in
        try await CleanupMeasurement.read(
        receipts: receipts, trash: cleanup.engine.trash, restored: restored, disk: disk, remeasurePaths: remeasurePaths,
        roots: roots, results: results, report: lastStorageReport(in: storageScope),
        simulatorListIncomplete: simulatorInventory?.note != nil, home: home, projects: protectedProjects,
        artifacts: projectArtifacts, interrupted: phase != .finished,
        priorRoots: phase != .finished && completedRoots?.scope == storageScope
          ? completedRoots?.roots ?? [] : [],
        priorResults: completedRoots?.scope == storageScope ? completedRoots?.results ?? [:] : [:])
      }
      await cleanup.engine.invalidateInspections(at: receipts.map(\.original))
      let manual = await ManualReview.candidates(
        roots: patch.roots, results: patch.results, rows: patch.freshItems, home: home,
        projects: protectedProjects, scope: patch.report?.scope)
      let states = phase == .finished ? try await cleanup.engine.actions(
        for: patch.freshItems, projects: protectedProjects, reportID: token,
        readings: patch.results.values.reduce(into: [:]) { $0.merge($1.cleanupReadings) { a, _ in a } },
        manual: manual.moves, restrictions: manual.blocked) : [:]
      guard generation == token else { return }
      for id in patch.removedIDs {
        manualMoves.removeValue(forKey: id)
        reviewRestrictions.removeValue(forKey: id)
      }
      manualMoves.merge(manual.moves) { _, fresh in fresh }
      reviewRestrictions.merge(manual.blocked) { _, fresh in fresh }
      volume = disk
      roots = patch.roots
      results = patch.results
      if phase == .finished, let storageScope { completedRoots = (storageScope, roots, results) }
      projectArtifacts = patch.artifacts
      for group in patch.affectedGroups {
        overviewCategories[group] = patch.categories[group]
        groupBytes[group] = patch.groupBytes[group]
      }
      if let snapshot = patch.report {
        for id in patch.removedIDs { actions.removeValue(forKey: id) }
        actions.merge(states) { _, fresh in fresh }
        report = snapshot
        // A partial reading isn't another historical full scan or a new growth alert.
        #if MACPURGE_BUNDLE
          if historyEnabled && phase == .finished { try updateWidget(snapshot, at: .now) }
        #endif
      }
      let originals = Set(receipts.map { $0.original.path })
      regrownFolders?.removeAll { originals.contains($0.move.receipt.original.path) }
    } catch { historyError = error.localizedDescription }
  }

  #if MACPURGE_BUNDLE
    private func updateWidget(_ snapshot: ScanReport, at date: Date) throws {
      guard let url = WidgetSnapshot.location else { return }
      let brief = WidgetSnapshot(
        date: date, free: snapshot.free,
        candidates: snapshot.items.reduce(0) { $0 + $1.eligibleBytes })
      try JSONEncoder().encode(brief).write(to: url, options: .atomic)
      WidgetCenter.shared.reloadTimelines(ofKind: BuildIdentity.widgetKind)
    }
  #endif
  func forgetRegrowth(at path: String) async throws {
    regrownFolders?.removeAll { $0.move.receipt.original.path == path }
    if historyEnabled { try await HistoryIO.shared.forgetMove(at: path) }
  }

  func setHistory(_ enabled: Bool) async {
    historyEnabled = enabled
    defaults.set(enabled, forKey: "keepsScanArchive")
    if !enabled {
      history = []
      regrownFolders = nil
      do {
        try await HistoryIO.shared.clear()
        historyError = nil
      } catch { historyError = error.localizedDescription }
      #if MACPURGE_BUNDLE
        if let url = WidgetSnapshot.location, FileManager.default.fileExists(atPath: url.path) {
          do {
            try FileManager.default.removeItem(at: url)
            WidgetCenter.shared.reloadTimelines(ofKind: BuildIdentity.widgetKind)
          } catch { historyError = error.localizedDescription }
        }
      #endif
    }
  }

  func setHistoryRetention(_ retention: ActivityRetention) async {
    historyRetention = retention
    defaults.set(retention.rawValue, forKey: ActivityRetention.preference)
    if let cutoff = retention.cutoff(at: .now) { history.removeAll { $0.date < cutoff } }
    do {
      try await HistoryIO.shared.prune(retention: retention)
      if historyRetention == retention { historyError = nil }
    } catch { historyError = error.localizedDescription }
  }

  func chooseExcludedFolders() {
    let panel = NSOpenPanel()
    panel.title = ReviewLanguage.text("Exclude folders from scans")
    panel.prompt = ReviewLanguage.text("Exclude folders")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let self else { return }
      addExcludedFolders(panel.urls)
    }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
    else { panel.begin(completionHandler: completion) }
  }

  func addExcludedFolders(_ urls: [URL]) {
    guard !cleanup.busy else { return }
    let paths = excludedFolders.map(\.path) + urls.filter(\.isFileURL).map {
      guard let path = realpath($0.path, nil) else { return $0.path }
      defer { free(path) }
      return String(cString: path)
    }
    updateExcludedFolders(ScanExclusions(paths: paths).paths)
  }

  func removeExcludedFolder(_ url: URL) {
    guard !cleanup.busy else { return }
    updateExcludedFolders(excludedFolders.filter { $0.path != url.path }.map(\.path))
  }

  private func updateExcludedFolders(_ paths: [String]) {
    guard paths != excludedFolders.map(\.path) else { return }
    excludedFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    defaults.set(paths, forKey: ScanExclusions.preference)
    cleanup.preview = nil
    cleanup.permanentReview = nil
    start()
  }

  private func register(_ batch: [ScanRoot], replacing: Bool = false) {
    roots = replacing ? batch : roots + batch
    var categories = replacing ? [:] : overviewCategories
    for root in batch { categories[root.group, default: OverviewCategory()].register(root) }
    overviewCategories = categories
  }

  func start() {
    guard !cleanup.busy else { return }
    let previous = work
    previous?.cancel()
    let token = UUID()
    generation = token
    let home = self.home
    let exclusions = ScanExclusions(paths: excludedFolders.map(\.path))
    var locations = ScanRoot.catalog(home: home, projects: projects)
    if let clang = ExtendedInventory.clangModuleCache(home: home) { locations.append(clang) }
    let catalog = locations.compactMap(exclusions.applying)
    let extended = detailed
    let selectedProjects = projects
    let includeProtected = defaults.bool(forKey: "scanProtectedLocations")
    let scope = ScanReport.scopeKey(
      extended: extended, protected: includeProtected, projects: selectedProjects, exclusions: exclusions.paths)
    if storageScope != scope { previousActions = [:] }
    else if !actions.isEmpty { previousActions = actions }
    actions = [:]
    manualMoves = [:]
    reviewRestrictions = [:]
    regrownFolders = nil
    storageScope = scope
    var last = lastStorageReport(in: scope)
    storagePreview = last
    pendingCategories = last == nil ? Set(ScanGroup.allCases) : []
    register(catalog, replacing: true)
    results = [:]
    groupBytes = [:]
    simulatorInventory = nil
    projectArtifacts = []
    projectDiscovery = ProjectDiscovery()
    activeRoot = nil
    measuredAt = nil
    progressStage = .discovering
    phase = .running
    work = Task(priority: .utility) { [weak self] in
      // Wait for any cancelled directory walk to release its descriptors.
      await previous?.value
      guard let self else { return }
      await ScanExclusions.$current.withValue(exclusions) { [self] in
        guard generation == token, !Task.isCancelled else { return }
        if !loadedHistory && historyEnabled {
          do {
            try await HistoryIO.shared.prune(retention: historyRetention)
            let saved = try await HistoryIO.shared.load(retention: historyRetention)
            guard generation == token, !Task.isCancelled else { return }
            if historyEnabled {
              let cutoff = historyRetention.cutoff(at: .now)
              history = saved.filter { cutoff == nil || $0.date >= cutoff! }
              report = history.first { $0.scope == scope }
              last = last ?? history.first { $0.scope == scope }
              storagePreview = last
              if last != nil { pendingCategories = [] }
            }
          } catch { historyError = error.localizedDescription }
          loadedHistory = true
        }
        let volumes = await ScanVolumes.read(home: home, projects: selectedProjects)
        let disk = await VolumeReading.read(at: home)
        guard generation == token, !Task.isCancelled else { return }
        volume = disk
        volumeDevice = volumes.device(for: home)
        do {
          let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices")
          let inventory = try await SimulatorInventory.discover(
            in: devices, onDevice: volumes.device(for: devices))
          guard generation == token, !Task.isCancelled else { return }
          simulatorInventory = inventory
          let deviceStatus =
            inventory.note.map { note in
              [
                ScanRoot(
                  group: .simulators, title: "Cihaz listesi",
                  url: home.appending(path: "Library/Developer/CoreSimulator/Devices"),
                  source: .status(note))
              ]
            } ?? []
          let projectInventory = try await ProjectDiscovery.discover(
            catalog.filter { $0.group == .projects }.map(volumes.restrict))
          try Task.checkCancellation()
          guard generation == token else { return }
          projectDiscovery = projectInventory
          let protected = protectedProjects
          let outputs = try await ProjectAttribution.outputRoots(
            home: home, selected: protected,
            onDevice: volumes.device(for: home.appending(path: "Library/Developer/Xcode/DerivedData"))
          )
          let compilerCaches = try await ProjectAttribution.compilerCacheRoots(
            in: home, onDevice: volumes.device(for: home.appending(path: "Library/Developer/Xcode/DerivedData")))
          let npx = home.appending(path: ScanRoot.npxCachePath)
          let npxEntries = try await DevelopmentCache.npxRoots(in: home, onDevice: volumes.device(for: npx))
          guard generation == token, !Task.isCancelled else { return }
          let boundaries = CleanupMeasurement.Boundaries(
            home: home, trash: cleanup.engine.trash,
            devices: inventory.roots, catalog: catalog + compilerCaches + npxEntries)
          let partitioned = catalog.filter { $0.group != .projects } + projectInventory.roots
          var quick = (partitioned + inventory.roots + deviceStatus + outputs + compilerCaches + npxEntries).map(volumes.restrict).map(
            boundaries.partition).compactMap(exclusions.applying)
          if let index = quick.firstIndex(where: { $0.profile == .xcodeWorkspace }) {
            let prefix = quick[index].url.path + "/"
            quick[index].excludedDirectories.formUnion(
              (outputs + compilerCaches).map { String($0.url.path.dropFirst(prefix.count)) })
          }
          if let index = quick.firstIndex(where: { $0.url.path == npx.path }) {
            quick[index].excludedDirectories.formUnion(npxEntries.map { $0.url.lastPathComponent })
          }
          let dev = volumes.device(for: home)
          let builder = ScanReportBuilder(
            id: token, scope: scope, extended: extended, disk: disk, device: dev)
          @MainActor func publish(
            _ batch: [ScanRoot], pending: Set<ScanGroup>, sizes: [ScanGroup: GroupSize]
          ) async throws {
            try Task.checkCancellation()
            await builder.append(batch, results: results)
            guard recordsHistory else { return }
            let preview = try await builder.snapshot(
              roots: roots, results: results, sizes: sizes,
              pending: pending, simulatorListIncomplete: inventory.note != nil, last: last)
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            storagePreview = preview
            pendingCategories = last == nil ? pending : []
          }
          register(quick, replacing: true)
          progressStage = .measuring(title: "Temel konumlar", start: 0, total: quick.count)
          await MeasurementCache.shared.configure(quick, preserveEntries: extended)
          func measure(_ members: [ScanRoot], _ prior: [ScanGroup: GroupSize] = [:]) async throws
            -> [ScanGroup: GroupSize]
          {
            try await StorageMeter.scan(members, startingWith: prior, cache: MeasurementCache.shared)
            { root in
              if self.generation == token { self.activeRoot = root }
            } onFinish: { root, result, total in
              guard self.generation == token else { return }
              self.results[root.id] = result
              self.groupBytes[root.group] = total
              self.overviewCategories[root.group]?.record(result, for: root)
              #if MACPURGE_PROFILE
                if result.measured { StartupProbe.firstResult() }
              #endif
            }
          }
          var totals: [ScanGroup: GroupSize] = [:]
          let quickBatches = Dictionary(grouping: quick, by: \.group)
          var quickPending = extended ? Set(ScanGroup.allCases) : Set(quickBatches.keys)
          for group in ScanGroup.allCases {
            guard let batch = quickBatches[group] else { continue }
            totals = try await measure(batch, totals)
            // Detailed discovery may still add roots to the initial categories, except projects.
            if !extended || group == .projects { quickPending.remove(group) }
            try await publish(batch, pending: quickPending, sizes: totals)
          }
          if extended {
            try Task.checkCancellation()
            activeRoot = nil
            progressStage = .discovering
            // Tool deadlines must not delay filesystem categories.
            async let tools = toolInventory(home, inventory)
            let local = try await localInventory(home, includeProtected, selectedProjects, volumes)
            var keys = Set(quick.map(\.id))
            var pending: Set<ScanGroup> = [.docker, .runtimes, .snapshots]
            if !selectedProjects.isEmpty { pending.insert(.other) }
            let deferred = pending
            @MainActor func scanBatches(
              _ incoming: [ScanRoot], title: String, keeping open: Set<ScanGroup>
            )
              async throws
            {
              try Task.checkCancellation()
              guard generation == token else { throw CancellationError() }
              let fresh = incoming.filter { keys.insert($0.id).inserted }.map(volumes.restrict).map(
                boundaries.partition).compactMap(exclusions.applying)
              register(fresh)
              if !fresh.isEmpty {
                progressStage = .measuring(title: title, start: results.count, total: fresh.count)
              }
              await MeasurementCache.shared.configure(roots, preserveEntries: true)
              let batches = Dictionary(grouping: fresh, by: \.group)
              pending = Set(batches.keys).union(open)
              try await publish([], pending: pending, sizes: totals)
              for group in ScanGroup.allCases {
                guard let batch = batches[group] else { continue }
                totals = try await measure(batch, totals)
                if !open.contains(group) { pending.remove(group) }
                try await publish(batch, pending: pending, sizes: totals)
              }
            }
            try await scanBatches(local, title: "Ek konumlar", keeping: deferred)
            try Task.checkCancellation()
            activeRoot = nil
            progressStage = .discovering
            let external = try await tools
            let scopePaths = Set(selectedProjects.map(\.path))
            let selectedRoots = quick.filter { $0.group == .projects && scopePaths.contains($0.url.path) }
            let projectFolders = try await ExtendedInventory.projectFolders(
              selectedRoots, results: results,
              claimed: (ScanRoot.catalog(home: home, projects: []) + local + external).map(\.url)
                + projectInventory.roots.filter { $0.profile == .projectOutput }.map(\.url))
            try await scanBatches(external + projectFolders, title: "Araç ve proje konumları", keeping: [])
            await MeasurementCache.shared.configure(roots)
          }
          guard generation == token, !Task.isCancelled else { return }
          activeRoot = nil
          progressStage = .finishing
          if let derived = catalog.first(where: { $0.profile == .xcodeWorkspace }) {
            let outputBytes = Dictionary(
              uniqueKeysWithValues: outputs.map {
                (
                  $0.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                  results[$0.id]?.bytes ?? 0
                )
              })
            let artifacts = try await ProjectAttribution.derive(
              home: home, selected: protected, measurement: results[derived.id],
              outputBytes: outputBytes)
            guard generation == token, !Task.isCancelled else { return }
            projectArtifacts = artifacts
          }
          if extended {
            let identities = Set(roots.compactMap(\.application))
            let index = ApplicationDiscovery(apps: identities.sorted { $0.path < $1.path }, roots: [])
            roots = roots.map { index.attributing($0, home: home) }
          }
          let snapshot = try await builder.snapshot(
            roots: roots, results: results, sizes: totals,
            pending: [], simulatorListIncomplete: inventory.note != nil, last: nil, final: true)
          guard generation == token, !Task.isCancelled else { return }
          let manual = await ManualReview.candidates(
            roots: roots, results: results, rows: snapshot.items, home: home,
            projects: protected, scope: snapshot.scope)
          guard generation == token, !Task.isCancelled else { return }
          manualMoves = manual.moves
          reviewRestrictions = manual.blocked
          report = snapshot
          measuredAt = snapshot.date
          completedRoots = (scope, roots, results)
          if historyEnabled {
            do {
              try await HistoryIO.shared.record(snapshot, retention: historyRetention)
              guard generation == token, !Task.isCancelled else { return }
              if historyEnabled {
                let cutoff = historyRetention.cutoff(at: .now)
                history = Array(([snapshot] + history).filter { cutoff == nil || $0.date >= cutoff! }.prefix(35))
              }
              if historyEnabled {
                let moves = try await HistoryIO.shared.movedFolders()
                let readings = try await MovedFolder.regrown(
                  moves, in: snapshot, history: history,
                  measuredCaches: cleanupReadings)
                guard generation == token, !Task.isCancelled else { return }
                if historyEnabled {
                  regrownFolders = readings
                  let known = Set(moves.filter { $0.rapidReturnAt != nil }.map(\.receipt.id))
                  let newlyVerified = readings.map(\.move).filter {
                    $0.rapidReturnAt != nil && !known.contains($0.receipt.id)
                  }
                  if !newlyVerified.isEmpty {
                    try await HistoryIO.shared.remember(newlyVerified, updatingEvidence: true)
                    guard generation == token, !Task.isCancelled else { return }
                  }
                }
              }
              historyError = nil
              #if MACPURGE_BUNDLE
                if historyEnabled { try updateWidget(snapshot, at: snapshot.date) }
              #endif
            } catch {
              guard generation == token, !Task.isCancelled else { return }
              historyError = error.localizedDescription
            }
          }
          guard generation == token, !Task.isCancelled else { return }
          storagePreview = nil
          pendingCategories = []
          phase = .finished
          if recordsHistory {
            await ScanAlerts.inspect(snapshot, previous: history, defaults: defaults)
          }
        } catch {
          if generation == token {
            phase = .cancelled
            if !(error is CancellationError) { historyError = error.localizedDescription }
          }
        }
        if generation == token {
          activeRoot = nil
          work = nil
        }
      }
    }
  }

  func cancel() {
    guard phase == .running else { return }
    generation = UUID()
    work?.cancel()
    activeRoot = nil
    phase = .cancelled
  }

  func chooseProjects() { chooseProjects(forLargeFolders: false) }
  func chooseLargeFolders() { chooseProjects(forLargeFolders: true) }

  private func chooseProjects(forLargeFolders: Bool) {
    let panel = NSOpenPanel()
    panel.title = ReviewLanguage.text(
      forLargeFolders
        ? "Büyük alt klasörlerin aranacağı konumları seç" : "Ölçülecek proje klasörlerini seç")
    panel.prompt = ReviewLanguage.text("Klasörleri ekle")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let self, !cleanup.busy else { return }
      if forLargeFolders { detailed = true }
      addProjects(panel.urls)
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

  func exportReport() {
    guard let report else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = ReviewLanguage.text("MacPurge-envanter.json")
    panel.message = ReviewLanguage.text("Dosya yolları dışa aktarımdan çıkarılır.")
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try report.export().write(to: url, options: .atomic) } catch {
        self.historyError = error.localizedDescription
      }
    }
  }

  func addProjects(_ urls: [URL]) {
    guard !cleanup.busy else { return }
    // Store only outermost selected roots. An included subfolder is already measured.
    let candidates = Set((projects + urls).filter(\.isFileURL).map(\.path))
    let ordered = candidates.sorted { ($0.count, $0) < ($1.count, $1) }
    var kept: [String] = []
    for path in ordered where !kept.contains(where: { path.hasPrefix($0 == "/" ? "/" : $0 + "/") })
    {
      kept.append(path)
    }
    selectionNote =
      kept.count < candidates.count
      ? "İç içe seçilen klasörler üst klasör altında bir kez ölçülür." : nil
    projects = kept.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    saveSelectionAndScan()
  }

  func exclude(_ url: URL) {
    guard !cleanup.busy else { return }
    projects.removeAll { $0.path == url.path }
    selectionNote = nil
    saveSelectionAndScan()
  }

  private func saveSelectionAndScan() {
    defaults.set(projects.map(\.path), forKey: Self.preference)
    start()
  }
}

func byteLabel(_ bytes: Int64) -> String {
  bytes.formatted(
    .byteCount(style: .file, spellsOutZero: false)
      .locale(ReviewLanguage.locale(ReviewLanguage.current))
  )
}
