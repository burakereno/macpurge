import AppIntents
import AppKit
import Foundation
import UserNotifications
import WidgetKit

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

// CLI and Shortcuts share the GUI ranking but never write history while preparing a plan.
private func readOnlyPlan(
  _ report: ScanReport, target: Int64, hidden: Set<String>, states: [String: MoveAvailability],
  history: [ScanReport]? = nil, measuredCaches: [String: DirectoryReading]? = nil
) async throws -> [ReportItem] {
  let prefs = UserDefaults.standard
  var readings: [RegrownFolder] = []
  if prefs.object(forKey: "keepsScanArchive") == nil || prefs.bool(forKey: "keepsScanArchive") {
    let paths = Dictionary(
      uniqueKeysWithValues: report.items.filter {
        $0.safePlanCandidate && !hidden.contains($0.id) && states[$0.id] == .ready
      }.map { ($0.id, $0.path) })
    if paths.count > 1, let moves = try? await HistoryIO.shared.movedFolders() {
      let now = Date.now
      let relevant = moves.filter { move in
        guard let path = paths[move.itemID] else { return false }
        if let proof = move.rapidReturnAt {
          return now.timeIntervalSince(proof) <= MovedFolder.planningHorizon
        }
        // Only exact folder rows can provide an observation from an older archived scan.
        let window =
          MovedFolder.rapidWindow
          + (path == move.receipt.original.path ? MovedFolder.planningHorizon : 0)
        return now.timeIntervalSince(move.receipt.date) <= window
      }
      var earlier = history ?? []
      if history == nil
        && relevant.contains(where: {
          $0.rapidReturnAt == nil && paths[$0.itemID] == $0.receipt.original.path
        })
      {
        earlier = (try? await HistoryIO.shared.load()) ?? []
      }
      readings = try await MovedFolder.regrown(
        relevant, in: report, history: earlier, measuredCaches: measuredCaches)
    }
  }
  try Task.checkCancellation()
  return report.plan(target: target, excluding: hidden, moveStates: states, regrowth: readings)
}

@main
enum MacPurgeEntry {
  @MainActor static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--verify-package") {
      guard args.count == 2, args.first == "--verify-package" else { exit(2) }
      do {
        print(try await PayloadVerification.inspect(URL(fileURLWithPath: args[1])))
        exit(0)
      } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
      }
    }
    if args.contains("--json") || args.contains("--plan") || args.contains("--help") {
      let status = await runCLI(args)
      exit(status)
    }
    ReleasePreferences.migrate()
    ReviewLanguage.apply(ReviewLanguage.current)
    MacPurgeApp.main()
  }

  @MainActor private static func runCLI(_ args: [String]) async -> Int32 {
    let usage = "MacPurge --json [--extended] [--paths] | --plan <GB> [--extended]"
    if args.contains("--help") {
      print(usage)
      return 0
    }
    let allowed: Set<String> = ["--json", "--plan", "--extended", "--paths"]
    let plan = args.firstIndex(of: "--plan")
    var goal: Int64?
    if let plan, plan + 1 < args.count, let gb = Int64(args[plan + 1]), (1...100_000).contains(gb) {
      goal = gb * 1_000_000_000
    }
    let bad = args.enumerated().contains { i, arg in
      !allowed.contains(arg) && !(plan.map { $0 + 1 == i } ?? false)
    }
    guard !bad, plan == nil || goal != nil, !(args.contains("--json") && plan != nil) else {
      FileHandle.standardError.write(Data((usage + "\n").utf8))
      return 2
    }
    let model = LiveScan(recordsHistory: false)
    if args.contains("--extended") { model.startDetailed() } else { model.startQuick() }
    await model.finishCurrentScan()
    guard model.phase == .finished, let report = model.report else { return 1 }
    do {
      if let goal {
        let states = try await CacheTrash.shared.availability(
          for: report.items, projects: model.protectedProjects, reportID: report.id,
          readings: model.cleanupReadings)
        let rows = try await readOnlyPlan(
          report, target: goal, hidden: model.hiddenIDs, states: states,
          measuredCaches: model.cleanupReadings)
        struct Preview: Encodable {
          let targetBytes: Int64
          let candidateBytes: Int64
          let shortfallBytes: Int64
          let items: [String]
          let applied: Bool
        }
        let sum = rows.reduce(0) { $0 + $1.eligibleBytes }
        let value = Preview(
          targetBytes: goal, candidateBytes: sum, shortfallBytes: max(0, goal - sum),
          items: rows.map(\.name), applied: false)
        FileHandle.standardOutput.write(try JSONEncoder().encode(value))
      } else {
        FileHandle.standardOutput.write(try report.export(includePaths: args.contains("--paths")))
      }
      FileHandle.standardOutput.write(Data("\n".utf8))
      return 0
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      return 1
    }
  }
}

struct LastDiskScanIntent: AppIntent {
  static let title: LocalizedStringResource = "Son disk ölçümünü al"
  static let description = IntentDescription(
    "MacPurge’ün kaydettiği son ölçümün boş alanını ve tarihini getirir.")
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let report = try await HistoryIO.shared.load().first else {
      return .result(value: ReviewLanguage.text("Henüz kayıtlı tarama yok."))
    }
    return .result(value: ReviewLanguage.format("%@ · %@ boş", report.date.formatted(), report.free.map(byteLabel) ?? "—"))
  }
}

struct DiskPlanIntent: AppIntent {
  static let title: LocalizedStringResource = "Alan planı oluştur"
  @Parameter(title: "Hedef (GB)", default: 20) var gigabytes: Int
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let projects = LiveScan.selectedProjects()
    let protect = UserDefaults.standard.bool(forKey: "scanProtectedLocations")
    let history = try await HistoryIO.shared.load()
    guard
      let report = history.first(where: {
        $0.scope
          == ScanReport.scopeKey(extended: $0.extended, protected: protect, projects: projects,
            exclusions: ScanExclusions.saved().paths)
      })
    else { return .result(value: ReviewLanguage.text("Henüz kayıtlı tarama yok.")) }
    let target = Int64(min(100_000, max(gigabytes, 1))) * 1_000_000_000
    let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenRows") ?? [])
    let current = try await CacheTrash.shared.currentPlanInputs(
      report, projects: projects, hidden: hidden)
    let rows = try await readOnlyPlan(
      current.report, target: target, hidden: hidden,
      states: current.states, history: history)
    let sum = rows.reduce(0) { $0 + $1.eligibleBytes }
    return .result(
      value:
        ReviewLanguage.format("%lld aday · %@ · Eksik %@ · Önizleme", Int64(rows.count), byteLabel(sum), byteLabel(max(0,target-sum))))
  }
}

struct MacPurgeShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: LastDiskScanIntent(), phrases: ["Get the last disk scan with \(.applicationName)"],
      shortTitle: "Son ölçüm", systemImageName: "externaldrive")
    AppShortcut(
      intent: DiskPlanIntent(), phrases: ["Create a space plan with \(.applicationName)"],
      shortTitle: "Alan planı", systemImageName: "scope")
  }
}

@MainActor
final class NoticeDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  var showActivity: (() -> Void)?
  var showSettings: (() -> Void)?
  var showWorkspace: (() -> Void)?

  private var settingsShortcut: Any?

  private var isMenuOnlyLogin: Bool {
    guard !AppPresence.Location.saved().hasDock,
      let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventID == kAEOpenApplication else { return false }
    return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(AppPresence.Location.saved().hasDock ? .regular : .accessory)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { showWorkspace?() }
    return true
  }

  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
    !isMenuOnlyLogin
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    UpdateChecker.shared.start()
    if isMenuOnlyLogin {
      // A restored workspace can already exist even when no new window was requested.
      NSApp.hide(nil)
    }
    // ⌘, remains available when the sidebar is collapsed, without a second Settings menu.
    settingsShortcut = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.charactersIgnoringModifiers == ",",
        event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
        NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil,
        let open = self?.showSettings else { return event }
      open()
      return nil
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.notification.request.identifier == "macpurge.storage" else { return }
    await MainActor.run { self.showActivity?() }
  }
}

@MainActor enum ScanAlerts {
  static func request() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
  }
  static func inspect(_ report: ScanReport, previous: [ScanReport], defaults: UserDefaults) async {
    guard defaults.bool(forKey: "alertsEnabled") else { return }
    let limit = Int64(max(1, defaults.object(forKey: "lowSpaceGB") as? Int ?? 10)) * 1_000_000_000
    var notes: [String] = []
    if let free = report.free {
      let low = free < limit
      if low && !defaults.bool(forKey: "lastWasLow") {
        notes.append(ReviewLanguage.format("Boş alan %@ seviyesine düştü.", byteLabel(free)))
      }
      defaults.set(low, forKey: "lastWasLow")
    }
    let same = previous.filter { $0.id != report.id && $0.extended == report.extended }
    if defaults.bool(forKey: "growthAlerts") {
      var sent = defaults.dictionary(forKey: "reportedGrowth") as? [String: Int64] ?? [:]
      for (group, size, delta) in report.unusualGroups(previous: same) {
        if let prior = sent[group], size - prior < 2 * 1024 * 1024 * 1024 { continue }
        notes.append("\(ReviewLanguage.text(group)) · +\(byteLabel(delta))")
        sent[group] = size
      }
      defaults.set(sent, forKey: "reportedGrowth")
    }
    if defaults.bool(forKey: "weeklySummary"),
      Date.now.timeIntervalSince1970 - defaults.double(forKey: "lastWeeklySummary") >= 604800,
      let baseline = same.first(where: { report.date.timeIntervalSince($0.date) >= 604800 }),
      let top = report.growth(since: baseline).first, top.1 > 2_000_000_000
    {
      notes.append(ReviewLanguage.format("Haftanın en büyük artışı: %@ · %@", top.0.actionTitle, byteLabel(top.1)))
      defaults.set(Date.now.timeIntervalSince1970, forKey: "lastWeeklySummary")
    }
    guard !notes.isEmpty else { return }
    let content = UNMutableNotificationContent()
    content.title = "MacPurge"
    content.body = notes.joined(separator: "\n")
    try? await UNUserNotificationCenter.current().add(
      .init(identifier: "macpurge.storage", content: content, trigger: nil))
  }
}
