import AppKit
import Observation
import WidgetKit

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum ScanPhase: Equatable { case idle, running, cancelled, finished }

@MainActor @Observable final class LiveScan {
  let cleanup = CleanupSession()
  private static let preference = "liveScan.selectedProjectPaths"
  private let defaults: UserDefaults
  let recordsHistory: Bool
  private(set) var projects: [URL]
  private(set) var roots: [ScanRoot] = []
  private(set) var results: [String: RootSize] = [:]
  private(set) var groupBytes: [ScanGroup: Int64] = [:]
  private(set) var activeRoot: ScanRoot?
  private(set) var phase: ScanPhase = .idle
  private(set) var measuredAt: Date?
  private(set) var report: ScanReport?
  private(set) var storagePreview: ScanReport?
  private(set) var pendingCategories = Set<ScanGroup>()
  private(set) var history: [ScanReport] = []
  private(set) var regrownFolders: [RegrownFolder]?
  private(set) var historyEnabled: Bool
  private(set) var detailed = true
  private(set) var historyError: String?
  @ObservationIgnored private var loadedHistory = false
  private(set) var volume: VolumeReading?
  private(set) var simulatorInventory: SimulatorInventory?
  private(set) var projectArtifacts: [ProjectArtifact] = []
  private(set) var hiddenIDs: Set<String>
  private(set) var selectionNote: String?
  @ObservationIgnored private var work: Task<Void, Never>?
  private var generation = UUID()
  private(set) var moveStates: [String: MoveAvailability] = [:]

  func refreshMoveStates() async {
    guard phase == .finished, let report else { return }
    moveStates = [:]
    guard
      let states = try? await CacheTrash.shared.availability(for: report.items, projects: projects),
      !Task.isCancelled, phase == .finished, self.report?.id == report.id
    else { return }
    moveStates = states
  }

  init(defaults: UserDefaults = .standard, recordsHistory: Bool = true) {
    self.defaults = defaults
    self.recordsHistory = recordsHistory
    hiddenIDs = Set(defaults.stringArray(forKey: "hiddenRows") ?? [])
    historyEnabled =
      recordsHistory
      && (defaults.object(forKey: "keepsScanArchive") == nil
        || defaults.bool(forKey: "keepsScanArchive"))
    projects = (defaults.stringArray(forKey: Self.preference) ?? []).map {
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
            WidgetCenter.shared.reloadTimelines(ofKind: "MacPurge.Disk")
          } catch { historyError = error.localizedDescription }
        }
      #endif
    }
  }

  func start() {
    guard !cleanup.busy else { return }
    let previous = work
    previous?.cancel()
    let token = UUID()
    generation = token
    let home = FileManager.default.homeDirectoryForCurrentUser
    let catalog = ScanRoot.catalog(home: home, projects: projects)
    let extended = detailed
    let selectedProjects = projects
    let includeProtected = defaults.bool(forKey: "scanProtectedLocations")
    let scope = ScanReport.scopeKey(
      extended: extended, protected: includeProtected, projects: selectedProjects)
    moveStates = [:]
    storagePreview = nil
    pendingCategories = Set(ScanGroup.allCases)
    roots = catalog
    results = [:]
    groupBytes = [:]
    simulatorInventory = nil
    projectArtifacts = []
    activeRoot = nil
    measuredAt = nil
    phase = .running
    work = Task(priority: .utility) { [weak self] in
      // Wait for any cancelled directory walk to release its descriptors.
      await previous?.value
      guard let self, generation == token, !Task.isCancelled else { return }
      if !loadedHistory && historyEnabled {
        do {
          let saved = try await HistoryIO.shared.load()
          guard generation == token, !Task.isCancelled else { return }
          if historyEnabled {
            history = saved
            report = saved.first
          }
        } catch { historyError = error.localizedDescription }
        loadedHistory = true
      }
      let disk = await VolumeReading.read(at: home)
      guard generation == token, !Task.isCancelled else { return }
      volume = disk
      do {
        let inventory = try await SimulatorInventory.discover(
          in: home.appending(path: "Library/Developer/CoreSimulator/Devices"))
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
        let outputs = try await ProjectAttribution.outputRoots(
          home: home, selected: selectedProjects)
        var quick = catalog + inventory.roots + deviceStatus + outputs
        if let index = quick.firstIndex(where: { $0.profile == .xcodeWorkspace }) {
          let prefix = quick[index].url.path + "/"
          quick[index].excludedDirectories = Set(
            outputs.map { String($0.url.path.dropFirst(prefix.count)) })
        }
        var statInfo = stat()
        let dev = stat(home.path, &statInfo) == 0 ? statInfo.st_dev : nil
        @MainActor func withTotals(
          _ value: ScanReport, pending: Set<ScanGroup>, sizes: [ScanGroup: GroupSize]
        ) -> ScanReport {
          var snapshot = value
          snapshot.scope = scope
          snapshot.groupSafety = Dictionary(
            uniqueKeysWithValues: sizes.compactMap { group, size in
              size.breakdown.map { (group.rawValue, $0) }
            })
          snapshot.measuredGroupBytes = Dictionary(
            uniqueKeysWithValues: groupBytes.map { ($0.key.rawValue, $0.value) })
          snapshot.groups = Dictionary(
            uniqueKeysWithValues: Set(roots.map(\.group)).compactMap { group in
              let members = roots.filter { $0.group == group }
              guard
                !pending.contains(group), !(group == .simulators && inventory.note != nil),
                members.allSatisfy({
                  results[$0.id]?.state == .complete || results[$0.id]?.state == .absent
                })
              else { return nil }
              return (group.rawValue, groupBytes[group] ?? 0)
            })
          return snapshot
        }
        var stagedItems: [ReportItem] = []
        @MainActor func publish(
          _ batch: [ScanRoot], pending: Set<ScanGroup>, sizes: [ScanGroup: GroupSize]
        ) {
          guard recordsHistory, generation == token, !Task.isCancelled else { return }
          let part = ScanReport.make(
            roots: batch, results: results, disk: disk, extended: extended, homeDevice: dev)
          stagedItems += part.items
          storagePreview = withTotals(
            .init(
              id: token, date: .now, extended: extended, free: disk?.free,
              capacity: disk?.bytes, items: stagedItems), pending: pending, sizes: sizes)
          pendingCategories = pending
        }
        roots = quick
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
            #if MACPURGE_PROFILE
              if result.measured { StartupProbe.firstResult() }
            #endif
          }
        }
        var totals = try await measure(quick)
        if extended {
          publish(quick, pending: Set(ScanGroup.allCases).subtracting([.projects]), sizes: totals)
          let extra = try await ExtendedInventory.discover(
            home: home, includeProtected: includeProtected, simulatorInventory: inventory,
            selectedProjects: selectedProjects,
            projectMeasurements: Dictionary(
              uniqueKeysWithValues: catalog.filter { $0.group == .projects }.compactMap { root in
                results[root.id].map { (root.url.path, $0) }
              }))
          guard generation == token, !Task.isCancelled else { return }
          var keys = Set(quick.map(\.id))
          let fresh = extra.filter { keys.insert($0.id).inserted }
          roots.append(contentsOf: fresh)
          await MeasurementCache.shared.configure(roots)
          let batches = Dictionary(grouping: fresh, by: \.group)
          var pending = Set(batches.keys)
          publish([], pending: pending, sizes: totals)
          for group in ScanGroup.allCases {
            guard let batch = batches[group] else { continue }
            totals = try await measure(batch, totals)
            pending.remove(group)
            publish(batch, pending: pending, sizes: totals)
          }
        }
        guard generation == token, !Task.isCancelled else { return }
        if let derived = catalog.first(where: { $0.profile == .xcodeWorkspace }) {
          let outputBytes = Dictionary(
            uniqueKeysWithValues: outputs.map {
              (
                $0.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                results[$0.id]?.bytes ?? 0
              )
            })
          let artifacts = try await ProjectAttribution.derive(
            home: home, selected: selectedProjects, measurement: results[derived.id],
            outputBytes: outputBytes)
          guard generation == token, !Task.isCancelled else { return }
          projectArtifacts = artifacts
        }
        let snapshot = withTotals(
          ScanReport.make(
            roots: roots, results: results, disk: disk, extended: extended, homeDevice: dev),
          pending: [], sizes: totals)
        report = snapshot
        measuredAt = snapshot.date
        if historyEnabled {
          do {
            try await HistoryIO.shared.record(snapshot)
            guard generation == token, !Task.isCancelled else { return }
            if historyEnabled { history = Array(([snapshot] + history).prefix(35)) }
            if historyEnabled {
              let moves = try await HistoryIO.shared.movedFolders()
              let readings = try await MovedFolder.regrown(moves, in: snapshot)
              guard generation == token, !Task.isCancelled else { return }
              if historyEnabled { regrownFolders = readings }
            }
            historyError = nil
            #if MACPURGE_BUNDLE
              if historyEnabled, let url = WidgetSnapshot.location {
                let brief = WidgetSnapshot(
                  date: snapshot.date, free: snapshot.free,
                  candidates: snapshot.items.reduce(0) { $0 + $1.eligibleBytes })
                try JSONEncoder().encode(brief).write(to: url, options: .atomic)
                WidgetCenter.shared.reloadTimelines(ofKind: "MacPurge.Disk")
              }
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
    panel.prompt = "Klasörleri ekle"
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
    panel.nameFieldStringValue = "MacPurge-envanter.json"
    panel.message = "Dosya yolları dışa aktarımdan çıkarılır."
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
      .locale(ReviewLanguage.locale(UserDefaults.standard.string(forKey: "reviewLanguage") ?? "tr"))
  )
}
