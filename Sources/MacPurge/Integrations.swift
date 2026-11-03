import AppIntents
import AppKit
import Foundation
import UserNotifications
import WidgetKit

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
    ReviewLanguage.apply(UserDefaults.standard.string(forKey: "reviewLanguage") ?? "tr")
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
        let rows = report.plan(target: goal, excluding: model.hiddenIDs)
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
      return .result(value: "Henüz kayıtlı tarama yok.")
    }
    return .result(value: "\(report.date.formatted()) · \(report.free.map(byteLabel) ?? "—") boş")
  }
}

struct DiskPlanIntent: AppIntent {
  static let title: LocalizedStringResource = "Alan planı oluştur"
  @Parameter(title: "Hedef (GB)", default: 20) var gigabytes: Int
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let report = try await HistoryIO.shared.load().first else {
      return .result(value: "Henüz kayıtlı tarama yok.")
    }
    let target = Int64(min(100_000, max(gigabytes, 1))) * 1_000_000_000
    let rows = report.plan(
      target: target, excluding: Set(UserDefaults.standard.stringArray(forKey: "hiddenRows") ?? []))
    let sum = rows.reduce(0) { $0 + $1.eligibleBytes }
    return .result(
      value:
        "\(rows.count) aday · \(byteLabel(sum)) · Eksik \(byteLabel(max(0,target-sum))) · Önizleme")
  }
}

struct MacPurgeShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: LastDiskScanIntent(), phrases: ["\(.applicationName) ile son ölçümü al"],
      shortTitle: "Son ölçüm", systemImageName: "externaldrive")
    AppShortcut(
      intent: DiskPlanIntent(), phrases: ["\(.applicationName) ile alan planı oluştur"],
      shortTitle: "Alan planı", systemImageName: "scope")
  }
}

@MainActor
final class NoticeDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  static var showActivity: (() -> Void)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.notification.request.identifier == "macpurge.storage" else { return }
    await MainActor.run { Self.showActivity?() }
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
        notes.append("Boş alan \(byteLabel(free)) seviyesine düştü.")
      }
      defaults.set(low, forKey: "lastWasLow")
    }
    let same = previous.filter { $0.id != report.id && $0.extended == report.extended }
    if defaults.bool(forKey: "growthAlerts") {
      var sent = defaults.dictionary(forKey: "reportedGrowth") as? [String: Int64] ?? [:]
      for (group, size, delta) in report.unusualGroups(previous: same) {
        if let prior = sent[group], size - prior < 2 * 1024 * 1024 * 1024 { continue }
        notes.append("\(group) · +\(byteLabel(delta))")
        sent[group] = size
      }
      defaults.set(sent, forKey: "reportedGrowth")
    }
    if defaults.bool(forKey: "weeklySummary"),
      Date.now.timeIntervalSince1970 - defaults.double(forKey: "lastWeeklySummary") >= 604800,
      let baseline = same.first(where: { report.date.timeIntervalSince($0.date) >= 604800 }),
      let top = report.growth(since: baseline).first, top.1 > 2_000_000_000
    {
      notes.append("Haftanın en büyük artışı: \(top.0.name) · \(byteLabel(top.1))")
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
