import AppKit
import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct TrashTarget: Identifiable, Sendable {
  let itemID: String
  let name: String
  let path: URL
  var snapshot: CacheSnapshot
  var workspace: String?
  var review: ManualReview? = nil
  var id: String { path.path }
}

enum MoveAvailability: Equatable, Sendable {
  case ready
  case blocked(String)
  case inUse(String)

  var explanation: String? {
    switch self {
    case .ready: nil
    case .blocked(let reason), .inUse(let reason): reason
    }
  }
}

enum CleanupAction: Equatable, Sendable {
  // Cleanup amounts estimate space released after emptying Trash, excluding external hard links.
  case move(SafetyLevel, bytes: Int64)
  case permanent(PermanentCleanup, bytes: Int64, blocked: MoveAvailability? = nil)
  case unavailable(MoveAvailability)
  case measurement(String)

  var availability: MoveAvailability {
    switch self {
    case .move: .ready
    case .permanent(let operation, _, let blocked): blocked ?? .blocked(operation.warning)
    case .measurement(let reason): .blocked(reason)
    case .unavailable(let state): state
    }
  }
  var risk: SafetyLevel? {
    switch self {
    case .move(let risk, _): risk
    case .permanent: .review
    default: nil
    }
  }
  func safety(for item: ReportItem?) -> SafetyLevel? {
    if let risk { return risk }
    if case .unavailable = self { return item?.safety.flatMap(SafetyLevel.init(rawValue:)) }
    return nil
  }

  var permanentOperation: PermanentCleanup? {
    if case .permanent(let operation, _, nil) = self { operation } else { nil }
  }
  var bytes: Int64 {
    switch self {
    case .move(_, let size), .permanent(_, let size, nil): size
    default: 0
    }
  }
  var statusKey: String {
    switch self {
    case .move(let level, _): level.rawValue
    case .permanent: SafetyLevel.review.rawValue
    case .measurement: "Yalnızca ölçüm"
    case .unavailable(.inUse): "Kullanımda"
    case .unavailable: "Kullanılamıyor"
    }
  }
}
struct TrashPlan: Identifiable, Sendable {
  let id = UUID()
  let reportID: UUID
  var projects: [URL] = []
  var targets: [TrashTarget] = []
  var skipped: [String] = []
  var coveredReviews: [ManualReview] = []
  var applicationUninstall: ApplicationUninstall? { targets.first?.review?.applicationUninstall }
  var exclusions: [URL] = []
  var reclaimableBytes: Int64 { targets.reduce(0) { $0 + $1.snapshot.reclaimableBytes } }
  var needsReview: Bool {
    coveredReviews.contains(where: \.requiresAcknowledgement)
      || targets.contains { $0.review?.requiresAcknowledgement == true }
  }
}

/// Captures the targets authorized by the user's final action.
struct ConfirmedTrashPlan: Sendable {
  let plan: TrashPlan

  init?(
    confirming id: UUID, preview: inout TrashPlan?, currentReportID: UUID?,
    acknowledgedReview: Bool = false
  ) {
    guard let displayed = preview, displayed.applicationUninstall == nil,
      displayed.id == id, displayed.reportID == currentReportID,
      !displayed.needsReview || acknowledgedReview, !displayed.targets.isEmpty
    else { return nil }
    plan = displayed
    preview = nil
  }

  init?(removingApplication plan: TrashPlan) {
    guard plan.applicationUninstall != nil else { return nil }
    self.plan = plan
  }
}

struct TrashReceipt: Identifiable, Codable, Sendable {
  let id: UUID
  let original: URL
  let parent: FileIdentity
  let identity: FileIdentity
  let bytes: Int64
  let date: Date
  var review: ManualReview? = nil
  var reclaimableBytes: Int64? = nil
  var expectedRecoveryBytes: Int64 { reclaimableBytes ?? 0 }
  var trashName: String { original.lastPathComponent + " (MacPurge " + id.uuidString + ")" }
}

struct TrashOutcome: Sendable {
  let id = UUID()
  var moved: [TrashReceipt] = []
  var completedItems: Set<String> = []
  var notices: [String] = []
  var freeChange: Int64?
  var diskAfter: VolumeReading?
  var applicationUninstall = false
}

struct RenderCacheOwner {
  let folder: String
  let bundle: String
  static let all = [
    Self(folder: "Slack", bundle: "com.tinyspeck.slackmacgap"),
    Self(folder: "discord", bundle: "com.hnc.Discord"),
    Self(folder: "Code", bundle: "com.microsoft.VSCode"),
    Self(folder: "Cursor", bundle: "com.todesktop.230313mzl4w4u92"),
  ]
  static let leaves = ["GPUCache", "Code Cache"]
}

enum PackageTool: Sendable {
  case npm, go, pip, brew, gradle

  private var pattern: String {
    switch self {
    case .npm:
      #"^\s*(?:[^\s]*/|/(?:[^/\n]*[^\s/]/)*)?(?:npm|npx)(?:\s|$)|^\s*(?:[^\s]*/|/(?:[^/\n]*[^\s/]/)*)?node\s+(?:[^\n]*[ /])?(?:npm|npx)(?:-cli\.js)?(?:\s|$)"#
    case .gradle:
      #"^\s*(?:[^\s]*/)?(?:gradle|gradlew)(?:\s|$)|^\s*(?:[^\s]*/)?java\s+[^\n]*org\.gradle\.(?:launcher\.GradleMain|wrapper\.GradleWrapperMain|process\.internal\.worker\.GradleWorkerMain)(?:\s|$)"#
    case .go: #"^\s*(?:[^\s]*/|/(?:[^/\n]*[^\s/]/)*)?go(?:[1-9][\d.]*)?(?:\s|$)"#
    case .pip: #"(?:^|[ /])pip(?:[0-9]+(?:\.[0-9]+)*)?(?:\s|$)"#
    case .brew: #"(?:^|[ /])(?:brew|brew\.rb|brew\.sh)(?:\s|$)"#
    }
  }
  private static let patterns = Dictionary(
    uniqueKeysWithValues: [Self.npm, .go, .pip, .brew, .gradle].compactMap {
      tool -> (Self, NSRegularExpression)? in
      guard let regex = try? NSRegularExpression(pattern: tool.pattern, options: .anchorsMatchLines)
      else { return nil }
      return (tool, regex)
    })

  func isIdle(in listing: String, npxCachePath: String? = nil) -> Bool {
    guard listing.contains(where: { !$0.isWhitespace }), let regex = Self.patterns[self] else {
      return false
    }
    // npm exec can hand off to a process that keeps running from the cache.
    if self == .npm, let npxCachePath, listing.localizedCaseInsensitiveContains(npxCachePath + "/") {
      return false
    }
    return regex.firstMatch(in: listing, range: NSRange(listing.startIndex..., in: listing)) == nil
  }
}

struct SimulatorState: Sendable {
  let state: String
  var isAvailable = true
}

/// Authorization is derived from known local cache roots, never from a saved report's label alone.
actor CacheTrash {
  static let userTrash =
    (try? FileManager.default.url(
      for: .trashDirectory, in: .userDomainMask,
      appropriateFor: FileManager.default.homeDirectoryForCurrentUser, create: false))
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
  static let shared = CacheTrash(
    home: FileManager.default.homeDirectoryForCurrentUser,
    journal: BuildIdentity.supportDirectory.appending(path: "TrashReceipts"),
    trash: userTrash)
  let home: URL
  let journal: URL
  private let deviceSet: URL
  private let runSimulatorErase: @Sendable (UUID, URL) async throws -> Void
  private let simulatorStates: @Sendable () async throws -> [UUID: SimulatorState]
  private let xcodeIdle: @Sendable () async throws -> Bool
  private let packageIdle: @Sendable (PackageTool) async throws -> Bool
  private let developmentUse: @Sendable () async throws -> DevelopmentCacheUse
  private let ollamaIdle: @Sendable () async throws -> Bool
  private var availabilityReport: UUID?
  private struct DirectoryStamp: Equatable {
    let identity: FileIdentity
    let seconds: Int
    let nanoseconds: Int
    init(_ s: stat) {
      identity = FileIdentity(s)
      seconds = s.st_ctimespec.tv_sec
      nanoseconds = s.st_ctimespec.tv_nsec
    }
  }
  private var inspectedPaths:
    [URL: (stamp: DirectoryStamp?, result: Result<CacheSnapshot, any Error>)] = [:]
  let trash: URL
  private let readVolume: @Sendable (URL) async -> VolumeReading?

  init(
    home: URL, journal: URL, trash: URL? = nil,
    simulatorStates: (@Sendable () async throws -> [UUID: SimulatorState])? = nil,
    eraseSimulator: @escaping @Sendable (UUID, URL) async throws -> Void = { id, set in
      _ = try await CleanupCommand.run("/usr/bin/xcrun", ["simctl", "--set", set.path, "erase", id.uuidString])
    },
    xcodeIdle: @escaping @Sendable () async throws -> Bool = CacheTrash.xcodeIdle,
    packageIdle: @escaping @Sendable (PackageTool) async throws -> Bool = CacheTrash
      .packageIdle,
    readVolume: @escaping @Sendable (URL) async -> VolumeReading? = VolumeReading.read,
    ollamaIdle: @escaping @Sendable () async throws -> Bool = CacheTrash.ollamaIdle,
    developmentUse: @escaping @Sendable () async throws -> DevelopmentCacheUse = DevelopmentCacheUse.read
  ) {
    self.home = home
    self.journal = journal
    self.trash = trash ?? home.appending(path: ".Trash")
    let set = home.appending(path: "Library/Developer/CoreSimulator/Devices")
    deviceSet = set
    self.simulatorStates = simulatorStates ?? { try await Self.simulatorStates(in: set) }
    runSimulatorErase = eraseSimulator
    self.xcodeIdle = xcodeIdle
    self.packageIdle = packageIdle
    self.developmentUse = developmentUse
    self.readVolume = readVolume
    self.ollamaIdle = ollamaIdle
  }

  func diskReading() async -> VolumeReading? { await readVolume(home) }

  func invalidateInspections(at paths: [URL]) {
    for path in paths { inspectedPaths.removeValue(forKey: path) }
  }

  private enum Owner: Hashable {
    case package(PackageTool)
    case download(PackageDownloadCache)
    case xcode
    case generatedProject
    case development(DevelopmentCache, URL)
    case manual(String)
    case application(String)
    case appCache(AppCacheRule, URL)
    case uninstall(ApplicationUninstall)
    case simulator(UUID)
    case ollama

    var isAppCache: Bool {
      if case .appCache = self { return true }
      return false
    }

    var downloadCache: PackageDownloadCache? {
      if case .download(let cache) = self { return cache }
      return nil
    }
    var developmentCache: DevelopmentCache? {
      if case .development(let cache, _) = self { return cache }
      return nil
    }
  }

  private func parts(_ path: URL) -> [String]? {
    guard path.isFileURL, path.path.hasPrefix(home.path + "/") else { return nil }
    let components = path.path.dropFirst(home.path.count + 1).components(separatedBy: "/")
    guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
    return components
  }

  private func simulator(_ parts: [String]) -> UUID? {
    guard parts.count >= 5,
      Array(parts.prefix(4)) == ["Library", "Developer", "CoreSimulator", "Devices"]
    else { return nil }
    return UUID(uuidString: parts[4])
  }

  private func owner(_ path: URL, profile: StorageProfile? = nil) -> Owner? {
    if profile?.isMissingWorkspaceOutput == true {
      guard ProjectAttribution.derivedFolder(for: path, home: home) != nil else { return nil }
      return .development(.orphanIntermediates, path)
    }
    if let cache = DevelopmentCache.at(path, home: home) { return .development(cache, path) }
    if profile == nil || profile == .appCache, let rule = AppCacheRule.at(path, home: home) {
      return .appCache(rule, path)
    }
    if profile == .appCache { return nil }
    guard let p = parts(path) else { return nil }
    if p == [".gradle", "caches"] { return .package(.gradle) }
    if ProjectOutput.profile(for: path).assessment(for: .complete)?.level == .safe { return .generatedProject }
    if p == [".npm", "_cacache"] { return .package(.npm) }
    if p == ["Library", "Caches", "go-build"] { return .package(.go) }
    if let cache = PackageDownloadCache(rawValue: p.joined(separator: "/")) {
      return .download(cache)
    }
    if p.count == 4, p[0] == "Library", p[1] == "Application Support",
      RenderCacheOwner.leaves.contains(p[3]),
      let app = RenderCacheOwner.all.first(where: { $0.folder == p[2] })
    {
      return .application(app.bundle)
    }
    if ProjectAttribution.derivedFolder(for: path, home: home) != nil { return .xcode }
    guard let device = simulator(p) else { return nil }
    var scope = SimulatorDirectory.device
    for component in p.dropFirst(5) {
      if scope == .cache { return nil }  // only the cache boundary itself is a target
      scope = scope.descending(into: component)
    }
    return scope == .cache ? .simulator(device) : nil
  }

  private func owner(_ path: URL, review: ManualReview?, restoring: Bool = false) -> Owner? {
    guard let review else { return owner(path) }
    guard review.permits(path, home: home, restoring: restoring) else { return nil }
    if let uninstall = review.applicationUninstall { return .uninstall(uninstall) }
    if review.ollama != nil { return .ollama }
    if let existing = owner(path, profile: review.profile) { return existing }
    let npx = home.appending(path: ScanRoot.npxCachePath).path.lowercased()
    let candidate = path.path.lowercased()
    if candidate == npx || candidate.hasPrefix(npx + "/") || npx.hasPrefix(candidate + "/") {
      return restoring ? .package(.npm) : nil
    }
    if review.parentItemID != nil, let parentOwner = owner(path.deletingLastPathComponent()) {
      return parentOwner
    }
    return .manual(review.category)
  }

  static func simulatorStates(in set: URL) async throws -> [UUID: SimulatorState] {
    struct Inventory: Decodable {
      struct Device: Decodable {
        let udid: String
        let state: String
        let dataPath: String
        let isAvailable: Bool
      }
      let devices: [String: [Device]]
    }
    let data = try await InventoryCommand.output(
      "/usr/bin/xcrun", ["simctl", "--set", set.path, "list", "devices", "-j"])
    let devices = try JSONDecoder().decode(Inventory.self, from: data).devices.values.joined()
    return Dictionary(
      devices.compactMap { device in
        guard let id = UUID(uuidString: device.udid),
          device.dataPath == set.appending(path: device.udid + "/data").path
        else { return nil }
        return (id, SimulatorState(state: device.state, isAvailable: device.isAvailable))
      }, uniquingKeysWith: { first, _ in first })
  }

  private func simulatorEraseBlock(_ row: ReportItem, device: SimulatorDevice, state: SimulatorState?,
    protection: ProjectAttribution.ProtectedProjects) -> MoveAvailability? {
    let url = URL(fileURLWithPath: row.path)
    let root = ScanRoot(group: .simulators, title: device.name, url: url)
    guard row.category == ScanGroup.simulators.rawValue, row.basis == "allocated",
      row.complete || row.status == "partial", row.simulatorDataDevice == device,
      row.id == ScanReport.itemID(root, suffix: "/device"),
      url.deletingLastPathComponent().path == deviceSet.path,
      UUID(uuidString: url.lastPathComponent) == device.id,
      (try? TrashFiles.directory(url, enumerate: false) { _, info in
        row.directoryInode == info.st_ino && row.volume == info.st_dev && info.st_uid == getuid()
      }) == true
    else { return .blocked(ReviewLanguage.text("The measured simulator could not be verified. Rescan and try again.")) }
    if protection.containsProject(under: url) { return .blocked(ReviewLanguage.text("Seçili proje klasörünü içeriyor.")) }
    switch state?.isAvailable == true ? state?.state : nil {
    case "Shutdown": return nil
    case "Booted", "Booting", "Shutting Down", "Creating":
      return .inUse(ReviewLanguage.text("Shut down this simulator before erasing it."))
    default: return .blocked(ReviewLanguage.text("Xcode could not verify that this simulator is available and shut down."))
    }
  }

  func eraseSimulator(_ device: SimulatorDevice, row: ReportItem, projects: [URL]) async throws {
    let states = try await simulatorStates()
    if let reason = simulatorEraseBlock(row, device: device, state: states[device.id],
      protection: ProjectAttribution.ProtectedProjects(projects))?.explanation {
      throw CleanupFailure(reason)
    }
    try await runSimulatorErase(device.id, deviceSet)
  }

  static func xcodeIdle() async throws -> Bool {
    let data = try await InventoryCommand.output("/bin/ps", ["-axo", "comm="])
    let processes = String(decoding: data, as: UTF8.self).split(separator: "\n")
    return !processes.isEmpty
      && !processes.contains { command in
        let name = URL(fileURLWithPath: command.trimmingCharacters(in: .whitespaces))
          .lastPathComponent
        return name == "Xcode" || name == "xcodebuild"
      }
  }

  static func packageIdle(_ tool: PackageTool) async throws -> Bool {
    let data = try await InventoryCommand.output("/bin/ps", ["-axww", "-o", "args="])
    let npx = FileManager.default.homeDirectoryForCurrentUser.appending(path: ScanRoot.npxCachePath)
    return tool.isIdle(in: String(decoding: data, as: UTF8.self), npxCachePath: npx.path)
  }

  static func ollamaIdle() async throws -> Bool {
    let data = try await InventoryCommand.output("/bin/ps", ["-axo", "comm="])
    let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
      .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased() }
    return !names.isEmpty && !names.contains { $0.hasPrefix("ollama") }
  }

  private func verifyWorkspace(
    _ path: URL, expected: String?, projects: [URL], profile: StorageProfile = .xcodeIntermediate
  ) throws {
    guard let expected, let derived = ProjectAttribution.derivedFolder(for: path, home: home),
      let workspace = ProjectAttribution.outputWorkspace(in: derived, home: home, projects: projects),
      workspace.path == expected,
      workspace.profile == (profile.isMissingWorkspaceOutput ? .xcodeOrphanBuild : profile)
    else { throw CleanupFailure("Xcode proje eşleşmesi doğrulanamadı.") }
  }

  private func verifyXcodeTarget(_ target: TrashTarget, owner: Owner, projects: [URL]) throws {
    if let review = target.review, review.profile.isMissingWorkspaceOutput {
      try verifyWorkspace(target.path, expected: review.workspace, projects: projects, profile: review.profile)
    } else if owner == .xcode && target.review == nil {
      try verifyWorkspace(target.path, expected: target.workspace, projects: projects)
    }
  }

  private func cacheUse(for rows: [ReportItem]) async -> Result<DevelopmentCacheUse, any Error>? {
    guard rows.contains(where: {
      $0.profile == .appCache || $0.profile?.isMissingWorkspaceOutput == true
        || DevelopmentCache.at(URL(fileURLWithPath: $0.path), home: home) != nil
    })
    else { return nil }
    do { return .success(try await developmentUse()) }
    catch { return .failure(error) }
  }

  private func verifyIdle(
    _ owner: Owner, states: [UUID: SimulatorState]? = nil,
    cacheUse: Result<DevelopmentCacheUse, any Error>? = nil, restoring: Bool = false
  ) async throws {
    switch owner {
    case .development(let cache, let path):
      if cache == .orphanIntermediates { try await verifyIdle(.xcode) }
      let snapshot: DevelopmentCacheUse
      if let cacheUse { snapshot = try cacheUse.get() }
      else { snapshot = try await developmentUse() }
      try snapshot.verify(cache, at: path)
    case .ollama:
      guard try await ollamaIdle() else { throw CleanupFailure("Quit Ollama and wait for model downloads to stop before cleanup.", inUse: true) }
    case .package(let tool):
      guard try await packageIdle(tool) else {
        throw CleanupFailure(tool == .npm
          ? "npm veya npx çalışıyor. İşlem bitince önbellek temizlenebilir."
          : tool == .gradle ? "Gradle derlemesi çalışıyor. İşlem bitince yeniden dene."
          : "Paket yöneticisinin işlemi bitince yeniden dene.", inUse: true)
      }
    case .download(let cache):
      guard try await packageIdle(cache == .brew ? .brew : .pip) else {
        throw CleanupFailure("Paket yöneticisinin işlemi bitince yeniden dene.", inUse: true)
      }
    case .manual(let category):
      if category == ScanGroup.xcode.rawValue {
        try await verifyIdle(.xcode)
      } else if category == ScanGroup.android.rawValue {
        let listing = try await InventoryCommand.output("/bin/ps", ["-axo", "comm="])
        let commands = String(decoding: listing, as: UTF8.self).split(separator: "\n")
        guard !commands.isEmpty,
          !commands.contains(where: {
            let name = URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces))
              .lastPathComponent
            return name == "emulator" || name.hasPrefix("qemu-system-")
          })
        else { throw CleanupFailure("Android emülatörünü kapatıp yeniden dene.", inUse: true) }
      }
    case .generatedProject: break
    case .xcode:
      guard try await xcodeIdle() else {
        throw CleanupFailure("Xcode’u kapat ve derlemenin bitmesini bekle.", inUse: true)
      }
    case .appCache(let rule, let path):
      if !restoring { try rule.validate(path, home: home) }
      try await verifyIdle(.application(rule.bundle))
      let snapshot: DevelopmentCacheUse
      if let cacheUse { snapshot = try cacheUse.get() }
      else { snapshot = try await developmentUse() }
      try snapshot.verifyUnused([path])
    case .application(let bundle):
      if await MainActor.run(body: {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
      }) {
        throw CleanupFailure("Uygulamayı kapatıp yeniden dene.", inUse: true)
      }
    case .uninstall(let uninstall): try await uninstall.verifyIdle()
    case .simulator(let id):
      let live: [UUID: SimulatorState]
      if let states { live = states } else { live = try await simulatorStates() }
      if live[id]?.state == "Booted" { throw CleanupFailure("Simülatör çalışıyor.", inUse: true) }
      guard live[id]?.state == "Shutdown" else {
        throw CleanupFailure("Simülatörün kapalı olduğu doğrulanamadı.")
      }
    }
  }

  private func locations(
    _ row: ReportItem, projects: [URL], states: [UUID: SimulatorState]?, currentSizes: Bool,
    cacheUse: Result<DevelopmentCacheUse, any Error>?
  ) async throws
    -> [URL]
  {
    let root = URL(fileURLWithPath: row.path)
    guard row.containsExcludedFolders != true, row.complete, row.safety == SafetyLevel.safe.rawValue,
      currentSizes || row.eligibleBytes > 0,
      row.basis == "allocated"
    else { throw CleanupFailure("Tam ölçülmüş bir Güvenli öğe değil.") }
    if let owner = owner(root, profile: row.profile) {
      switch (owner, ScanGroup(rawValue: row.category)) {
      case (.package, .packages), (.download, .packages), (.application, .apps), (.application, .tools): break
      case (.appCache, .appCaches):
        guard row.profile == .appCache else { throw CleanupFailure("Hedef yolu doğrulanamadı.") }
      case (.development(.expo, _), .tools):
        guard row.profile == .expoDownloadCache else { throw CleanupFailure("Hedef yolu doğrulanamadı.") }
      case (.development(.compiler, _), .tools), (.development(.compiler, _), .xcode):
        guard row.profile == .xcodeCompilerCache || row.profile == .clangModuleCache
        else { throw CleanupFailure("Hedef yolu doğrulanamadı.") }
      case (.development(.orphanIntermediates, _), .xcode):
        guard row.profile == .xcodeOrphanBuild else { throw CleanupFailure("Hedef yolu doğrulanamadı.") }
        try verifyWorkspace(root, expected: row.workspace, projects: projects, profile: .xcodeOrphanBuild)
      case (.generatedProject, .projects):
        guard ProjectAttribution.owningRoot(workspace: root.path, selected: projects) != nil,
          ProjectOutput.profile(for: root).assessment(for: .complete)?.level == .safe
        else { throw CleanupFailure("Proje derleme çıktısı doğrulanamadı.") }
      case (.xcode, .xcode):
        try verifyWorkspace(root, expected: row.workspace, projects: projects)
      default: throw CleanupFailure("Öğe bu kategoriden taşınamaz.")
      }
      try await verifyIdle(owner, cacheUse: cacheUse)
      return [root]
    }
    guard let p = parts(root), p.count == 5, let id = simulator(p),
      row.category == ScanGroup.simulators.rawValue
    else {
      throw CleanupFailure("Bu konumda uygulama içinden işlem desteklenmiyor.")
    }
    try await verifyIdle(.simulator(id), states: states)
    let apps = root.appending(path: "data/Containers/Data/Application")
    var bases = [root.appending(path: "data")]
    do {
      bases += try DirectoryIndex.children(of: apps).filter {
        $0.directory && UUID(uuidString: $0.url.lastPathComponent) != nil
      }.map(\.url)
    } catch let error as DirectoryIndex.Problem where error.code == ENOENT {}
    return bases.flatMap { base in ["Library/Caches", "tmp"].map { base.appending(path: $0) } }
  }

  private func targets(
    for row: ReportItem, projects: [URL], states: [UUID: SimulatorState]?, reportID: UUID? = nil,
    onlyPath: URL? = nil, protection: ProjectAttribution.ProtectedProjects,
    readings: [String: DirectoryReading] = [:], currentSizes: Bool = false,
    cacheUse: Result<DevelopmentCacheUse, any Error>? = nil
  ) async throws
    -> [TrashTarget]
  {
    let paths = try await locations(
      row, projects: projects, states: states, currentSizes: currentSizes, cacheUse: cacheUse)
    guard let device = row.volume, try TrashFiles.directory(home, { _, s in s.st_dev }) == device
    else { throw CleanupFailure("Ölçülen disk değişti.") }
    guard try TrashFiles.directory(trash, enumerate: false, { _, s in s.st_dev }) == device,
      access(trash.path, W_OK | X_OK) == 0
    else { throw CleanupFailure("Çöp bu diskte kullanılamıyor.") }
    var targets: [TrashTarget] = []
    for path in paths where onlyPath == nil || onlyPath?.path == path.path {
      try Task.checkCancellation()
      guard let owner = owner(path, profile: row.profile) else { throw CleanupFailure("Hedef yolu doğrulanamadı.") }
      guard
        !protection.containsProject(under: path)
      else { throw CleanupFailure("Seçili proje klasörünü içeriyor.") }
      do {
        let review: ManualReview?
        switch owner {
        case .generatedProject:
          review = try ManualReview.generatedProject(row, path: path, projects: projects)
        case .package(.gradle):
          review = try ManualReview.gradleCache(row, path: path, home: home)
        case .development(.orphanIntermediates, _):
          guard let inode = row.directoryInode, row.workspace != nil else {
            throw CleanupFailure("Xcode proje eşleşmesi doğrulanamadı.")
          }
          review = ManualReview(workspace: row.workspace, scope: nil, title: row.name,
            profile: .xcodeOrphanBuild, category: row.category, path: path.path, device: device,
            inode: inode, file: false, warning: row.reason)
        default: review = nil
        }
        let stamp = try inspectedSnapshot(
          path, device: device, owner: owner, reportID: reportID,
          reading: readings[path.path], currentSizes: currentSizes, review: review)
        if owner.developmentCache == .orphanIntermediates {
          guard currentSizes || stamp.identity.inode == row.directoryInode else {
            throw CleanupFailure("Öğe taşınmış veya değiştirilmiş.")
          }
          guard stamp.reclaimableBytes > 0 else {
            throw CleanupFailure("Taşımaya uygun alan yok")
          }
        }
        if stamp.bytes > 0 {
          targets.append(
            .init(
              itemID: row.id, name: row.actionTitle, path: path, snapshot: stamp, workspace: row.workspace, review: review)
          )
        }
      } catch let error as POSIXError where error.code == .ENOENT { continue }
    }
    guard !targets.isEmpty else { throw CleanupFailure("Taşınabilecek ölçülmüş çıktı bulunamadı.") }
    return targets
  }

  // Reuse the tree walk for display only. Preview and apply always take fresh snapshots.
  private func inspectedSnapshot(
    _ path: URL, device: Int32, owner: Owner, reportID: UUID?,
    reading: DirectoryReading?, currentSizes: Bool, review: ManualReview? = nil
  ) throws
    -> CacheSnapshot
  {
    if currentSizes || (reportID != nil && owner.developmentCache == .orphanIntermediates) {
      return try TrashFiles.snapshot(
        path, on: device, allowSymlinks: owner == .xcode,
        download: owner.downloadCache, fingerprint: false, review: review, development: owner.developmentCache, appCache: owner.isAppCache)
    }
    guard let reportID else {
      return try TrashFiles.snapshot(
        path, on: device, allowSymlinks: owner == .xcode, download: owner.downloadCache,
        review: review, development: owner.developmentCache, appCache: owner.isAppCache)
    }
    if availabilityReport != reportID {
      inspectedPaths.removeAll()
      availabilityReport = reportID
    }
    // A replaced, removed or newly created root invalidates even a previously failed inspection.
    let stamp = try? TrashFiles.directory(path, enumerate: false) { _, s in DirectoryStamp(s) }
    if let cached = inspectedPaths[path], cached.stamp == stamp { return try cached.result.get() }
    if owner.developmentCache == nil, !owner.isAppCache, let reading, reading.verified, let stamp, stamp.identity.device == device,
      stamp.identity.inode == reading.inode, reading.device == device,
      stamp.seconds == reading.seconds, stamp.nanoseconds == reading.nanos
    {
      // Display only. The confirmed preview and the move always inspect the actual tree.
      return try TrashFiles.directory(path.deletingLastPathComponent(), enumerate: false) {
        _, parent in
        CacheSnapshot(
          parent: FileIdentity(parent), identity: stamp.identity, changeSeconds: reading.seconds,
          changeNanoseconds: reading.nanos, digest: Data(), bytes: reading.bytes)
      }
    }
    let reading = Result {
      try TrashFiles.snapshot(
        path, on: device, allowSymlinks: owner == .xcode,
        download: owner.downloadCache, fingerprint: false, review: review, development: owner.developmentCache, appCache: owner.isAppCache)
    }
    try Task.checkCancellation()
    inspectedPaths[path] = (stamp, reading)
    return try reading.get()
  }

  private func batchStates(for items: [ReportItem], currentSizes: Bool = false) async -> [UUID: SimulatorState]
  {
    guard
      items.contains(where: {
        (currentSizes || $0.eligibleBytes > 0 || $0.simulatorDataDevice != nil) && $0.category == ScanGroup.simulators.rawValue
      }
      )
    else { return [:] }
    return (try? await simulatorStates()) ?? [:]
  }

  func inspectApplication(_ app: ApplicationIdentity, projects: [URL], exclusions: [URL]) async throws
    -> ApplicationUninstall.Inspection
  {
    let policy = ScanExclusions(paths: exclusions.map(\.path))
    return try await ScanExclusions.$current.withValue(policy) {
      let initial = ApplicationUninstall(app: app, helperIDs: [])
      let bundle = initial.bundleURL
      let bundleMatch = ApplicationUninstall.Match(kind: .bundle)
      if let reason = ApplicationUninstall.protectedReason(app) {
        return .init(rows: [.init(candidate: .init(url: bundle, match: bundleMatch, blocked: reason))], blocker: reason)
      }
      guard initial.permits(bundle, home: home), !policy.overlaps(bundle) else {
        throw CleanupFailure("This application is outside the allowed uninstall locations or contains an excluded folder.")
      }
      try initial.verifyBundle()
      let volumes = ScanVolumes(home: home, projects: [])
      let (scope, groups) = try ApplicationUninstall.identify(app, volumes: volumes)
      let installed = try ApplicationInventory.installed(home: home, volumes: volumes)
      let otherCopy = await scope.copiesInstalled(in: installed)
      let (related, unreadable) = try scope.candidates(home: home, groups: groups, installed: installed, hasOtherCopy: otherCopy)
      let protection = ProjectAttribution.ProtectedProjects(projects)
      let trashDevice = try? TrashFiles.directory(trash, enumerate: false) { _, info in info.st_dev }
      var rows: [ApplicationUninstall.Row] = []
      for var candidate in [.init(url: bundle, match: bundleMatch)] + related {
        try Task.checkCancellation()
        if candidate.blocked == nil {
          do {
            guard !policy.overlaps(candidate.url), !protection.containsProject(under: candidate.url) else {
              throw CleanupFailure("Contains a project or folder excluded from cleanup.")
            }
            guard let trashDevice, access(trash.path, W_OK | X_OK) == 0 else {
              throw CleanupFailure("Çöp bu diskte kullanılamıyor.")
            }
            let target = try applicationTarget(candidate, scope: scope, device: trashDevice)
            rows.append(.init(candidate: candidate, target: target))
            continue
          } catch is CancellationError { throw CancellationError() }
          catch { candidate.blocked = error.localizedDescription }
        }
        rows.append(.init(candidate: candidate))
      }
      var blocker = rows.first?.candidate.blocked
      if blocker == nil {
        do { try await scope.verifyIdle() }
        catch is CancellationError { throw CancellationError() }
        catch { blocker = error.localizedDescription }
      }
      rows.sort {
        let a = $0.target?.snapshot.reclaimableBytes ?? -1
        let b = $1.target?.snapshot.reclaimableBytes ?? -1
        return a == b ? $0.id < $1.id : a > b
      }
      return .init(rows: rows, unreadable: unreadable, blocker: blocker)
    }
  }

  private func applicationTarget(_ candidate: ApplicationUninstall.Candidate, scope: ApplicationUninstall,
                                 device: dev_t) throws -> TrashTarget {
    let path = candidate.url
    let bundle = path.path == scope.app.path
    let name = bundle ? scope.app.name : path.lastPathComponent
    guard FileManager.default.isDeletableFile(atPath: path.path) else {
      throw CleanupFailure("Bu konum Çöp’e taşınamaz.")
    }
    let review = try TrashFiles.directory(path.deletingLastPathComponent(), enumerate: false) { parent, _ in
      var info = stat()
      guard fstatat(parent, path.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw TrashFiles.posix() }
      let type = info.st_mode & S_IFMT
      guard type == S_IFDIR || (!bundle && type == S_IFREG) else { throw CleanupFailure("Bu konum Çöp’e taşınamaz.") }
      return ManualReview(scope: nil, title: name, profile: .personal, category: ScanGroup.apps.rawValue,
        path: path.path, device: info.st_dev, inode: info.st_ino, file: type == S_IFREG,
        warning: candidate.match.explanation, applicationUninstall: scope)
    }
    guard review.permits(path, home: home), review.device == device else { throw CleanupFailure("Çöp bu diskte kullanılamıyor.") }
    let snapshot = try TrashFiles.snapshot(path, on: device, review: review)
    guard snapshot.identity.inode == review.inode else { throw CleanupFailure("Öğe taşınmış veya değiştirilmiş.") }
    return TrashTarget(itemID: ScanGroup.apps.rawValue + "|" + path.path, name: name, path: path, snapshot: snapshot, review: review)
  }

  func prepare(
    items: [ReportItem], reportID: UUID, projects: [URL], onlyPath: URL? = nil,
    manual: [String: ManualReview] = [:]
  ) async
    -> TrashPlan
  {
    var plan = TrashPlan(reportID: reportID, projects: projects)
    let protection = ProjectAttribution.ProtectedProjects(projects)
    let states = await batchStates(for: items)
    let use = await cacheUse(for: items)
    var seen = Set<String>()
    var verifiedReviews: [String: ManualReview] = [:]
    for row in items {
      do {
        try Task.checkCancellation()
        guard row.containsExcludedFolders != true else {
          throw CleanupFailure("Contains a folder excluded from scans.")
        }
        if let review = manual[row.id], row.safety == SafetyLevel.review.rawValue {
          let path = URL(fileURLWithPath: row.path)
          guard onlyPath == nil, row.complete, row.basis == "allocated",
            row.category == review.category, review.inCurrentProjects(projects),
            row.volume == review.device, row.directoryInode == review.inode,
            let owner = owner(path, review: review), !protection.containsProject(under: path),
            try TrashFiles.directory(trash, enumerate: false, { _, info in info.st_dev })
              == review.device,
            access(trash.path, W_OK | X_OK) == 0
          else { throw CleanupFailure("Bu konum Çöp’e taşınamaz.") }
          try review.ollama?.validate(path)
          try await verifyIdle(owner, cacheUse: use)
          if review.profile.isMissingWorkspaceOutput {
            try verifyWorkspace(path, expected: review.workspace, projects: projects, profile: review.profile)
          }
          var snapshot = try TrashFiles.snapshot(path, on: review.device, review: review,
            development: owner.developmentCache, appCache: owner.isAppCache)
          if review.ollama != nil && review.ollama?.mayShareBlocks != false { snapshot.sharedBytes = snapshot.bytes }
          guard snapshot.identity.inode == review.inode else {
            throw CleanupFailure("Öğe taşınmış veya değiştirilmiş.")
          }
          verifiedReviews[path.path] = review
          if seen.insert(path.path).inserted {
            plan.targets.append(
              .init(itemID: row.id, name: row.actionTitle, path: path, snapshot: snapshot, review: review))
          }
          continue
        }
        let paths = try await targets(
          for: row, projects: projects, states: states, onlyPath: onlyPath, protection: protection, cacheUse: use)
        plan.targets += paths.filter { seen.insert($0.path.path).inserted }
      } catch { plan.skipped.append(row.actionTitle + " · " + error.localizedDescription) }
    }
    // A parent preview explicitly includes its descendants. Never rename a child separately.
    let paths = Set(plan.targets.map { $0.path.path })
    plan.targets.removeAll { target in
      var parent = target.path.deletingLastPathComponent()
      while parent.path != "/" && !parent.path.isEmpty {
        if paths.contains(parent.path) { return true }
        parent.deleteLastPathComponent()
      }
      return false
    }
    for target in plan.targets where target.review != nil { verifiedReviews.removeValue(forKey: target.path.path) }
    plan.coveredReviews = verifiedReviews.values.sorted { $0.path < $1.path }
    return plan
  }

  func availability(
    for items: [ReportItem], projects: [URL], reportID: UUID? = nil,
    readings: [String: DirectoryReading] = [:]
  ) async throws
    -> [String: MoveAvailability]
  {
    try await inspectItems(items, projects: projects, reportID: reportID, readings: readings).states
  }

  func actions(
    for items: [ReportItem], projects: [URL], reportID: UUID, readings: [String: DirectoryReading],
    manual: [String: ManualReview], restrictions: [String: String]
  ) async throws -> [String: CleanupAction] {
    let deviceStates = await batchStates(for: items)
    let use = await cacheUse(for: items)
    let safe = try await inspectItems(items, projects: projects, reportID: reportID, readings: readings,
      deviceStates: deviceStates, cacheUse: use)
    let protection = ProjectAttribution.ProtectedProjects(projects)
    var checks: [Owner: MoveAvailability] = [:]
    var decisions: [String: CleanupAction] = [:]
    let trashDevice = try? TrashFiles.directory(trash, enumerate: false) { _, info in info.st_dev }
    for row in items {
      try Task.checkCancellation()
      if row.evidence?.inspectionOnly == true {
        decisions[row.id] = .measurement(ReviewLanguage.text("This data is available for inspection only. Manage it in its owning application."))
        continue
      }
      if row.containsExcludedFolders == true {
        decisions[row.id] = .measurement(ReviewLanguage.text("Contains a folder excluded from scans."))
        continue
      }
      let state = safe.states[row.id] ?? .blocked(ReviewLanguage.text("Ölçülemedi"))
      if let systemLogs = SystemLogStore.action(for: row) {
        decisions[row.id] = systemLogs
      } else if let device = row.simulatorDataDevice {
        let blocked = simulatorEraseBlock(row, device: device, state: deviceStates[device.id], protection: protection)
        decisions[row.id] = .permanent(.simulator(device), bytes: row.reclaimableBytes, blocked: blocked)
      } else if let review = manual[row.id] {
        let url = URL(fileURLWithPath: row.path)
        do {
          try review.ollama?.validate(url)
          if review.profile.isMissingWorkspaceOutput {
            try verifyWorkspace(url, expected: review.workspace, projects: projects, profile: review.profile)
          }
        }
        catch { decisions[row.id] = .measurement(error.localizedDescription); continue }
        guard review.inCurrentProjects(projects), let owner = owner(url, review: review) else {
          decisions[row.id] = .measurement(ReviewLanguage.text("Bu konum Çöp’e taşınamaz."))
          continue
        }
        if checks[owner] == nil {
          do { try await verifyIdle(owner, cacheUse: use); checks[owner] = .ready }
          catch { checks[owner] = Self.blockage(error) }
        }
        let ownerState = checks[owner] ?? .blocked(ReviewLanguage.text("Kontrol ediliyor…"))
        if ownerState != .ready {
          decisions[row.id] = .unavailable(ownerState)
        } else if trashDevice != review.device || access(trash.path, W_OK | X_OK) != 0 {
          decisions[row.id] = .unavailable(.blocked(ReviewLanguage.text("Çöp bu diskte kullanılamıyor.")))
        } else if !review.matchesCurrentItem(at: url) {
          decisions[row.id] = .unavailable(.blocked(ReviewLanguage.text("Öğe taşınmış veya değiştirilmiş.")))
        } else if !FileManager.default.isDeletableFile(atPath: row.path) {
          decisions[row.id] = .unavailable(.blocked(ReviewLanguage.text("Bu konum Çöp’e taşınamaz.")))
        } else if review.profile == .npxEntry {
          do {
            try DevelopmentCache.npx.validate(url)
            decisions[row.id] = .move(.review, bytes: row.reclaimableBytes)
          } catch { decisions[row.id] = .unavailable(Self.blockage(error)) }
        } else {
          decisions[row.id] = .move(.review, bytes: review.ollama != nil && review.ollama?.mayShareBlocks != false ? 0 : row.reclaimableBytes)
        }
      } else if let reason = restrictions[row.id] {
        decisions[row.id] = .measurement(ReviewLanguage.text(reason))
      } else if state == .ready {
        decisions[row.id] = .move(.safe, bytes: safe.reclaimableBytes[row.id] ?? 0)
      } else if row.safePlanCandidate {
        decisions[row.id] = .unavailable(state)
      } else {
        decisions[row.id] = .measurement(state.explanation ?? ReviewLanguage.text(row.reason))
      }
    }
    return decisions
  }

  private static func blockage(_ error: any Error) -> MoveAvailability {
    if let failure = error as? CleanupFailure, failure.inUse { return .inUse(failure.localizedDescription) }
    return .blocked(error.localizedDescription)
  }

  private func inspectItems(
    _ items: [ReportItem], projects: [URL], reportID: UUID? = nil,
    readings: [String: DirectoryReading] = [:], currentSizes: Bool = false,
    deviceStates: [UUID: SimulatorState]? = nil, cacheUse: Result<DevelopmentCacheUse, any Error>? = nil
  ) async throws
    -> (states: [String: MoveAvailability], bytes: [String: Int64],
      reclaimableBytes: [String: Int64], inodes: [String: UInt64])
  {
    let states: [UUID: SimulatorState]
    if let deviceStates { states = deviceStates } else { states = await batchStates(for: items, currentSizes: currentSizes) }
    let use: Result<DevelopmentCacheUse, any Error>?
    if let cacheUse { use = cacheUse } else { use = await self.cacheUse(for: items) }
    var inodes: [String: UInt64] = [:]
    var sizes: [String: Int64] = [:]
    var reclaimable: [String: Int64] = [:]
    let protection = ProjectAttribution.ProtectedProjects(projects)
    var output: [String: MoveAvailability] = [:]
    for row in items {
      try Task.checkCancellation()
      let reason: String
      if !row.complete {
        reason = row.status == "partial" ? "Ölçüm eksik" : "Ölçülemedi"
      } else if row.safety != SafetyLevel.safe.rawValue {
        reason = "Yalnızca inceleme"
      } else if row.bytes == 0 && !currentSizes {
        reason = "Klasör boş"
      } else if row.eligibleBytes == 0 && !currentSizes {
        reason = "Taşımaya uygun alan yok"
      } else {
        do {
          let targets = try await targets(
            for: row, projects: projects, states: states, reportID: reportID,
            protection: protection, readings: readings, currentSizes: currentSizes, cacheUse: use)
          sizes[row.id] = targets.reduce(0) { $0 + $1.snapshot.bytes }
          reclaimable[row.id] = targets.reduce(0) { $0 + $1.snapshot.reclaimableBytes }
          if currentSizes {
            if let exact = targets.first(where: { $0.path.path == row.path }) {
              inodes[row.id] = exact.snapshot.identity.inode
            }
          }
          output[row.id] = .ready
          continue
        } catch {
          output[row.id] = Self.blockage(error)
          continue
        }
      }
      output[row.id] = .blocked(ReviewLanguage.text(reason))
    }
    return (output, sizes, reclaimable, inodes)
  }

  func currentPlanInputs(_ report: ScanReport, projects: [URL], hidden: Set<String>) async throws
    -> (report: ScanReport, states: [String: MoveAvailability])
  {
    let exclusions = ScanExclusions.saved()
    let items = report.items.filter {
      !hidden.contains($0.id) && $0.containsExcludedFolders != true
        && !exclusions.overlaps(URL(fileURLWithPath: $0.path))
        && $0.complete && $0.safety == SafetyLevel.safe.rawValue
    }
    let inspection = try await inspectItems(items, projects: projects, currentSizes: true)
    let now = Date.now
    let rows = items.compactMap { row -> ReportItem? in
      guard let bytes = inspection.bytes[row.id] else { return nil }
      var row = row
      row.bytes = bytes
      row.eligibleBytes = inspection.reclaimableBytes[row.id] ?? 0
      row.sharedLinkBytes = max(0, bytes - row.eligibleBytes)
      row.measuredAt = now
      if let inode = inspection.inodes[row.id] { row.directoryInode = inode }
      return row
    }
    return (
      ScanReport(
        id: report.id, date: now, extended: report.extended, free: report.free,
        capacity: report.capacity, items: rows, scope: report.scope), inspection.states
    )
  }

  private func receiptsFile(_ id: UUID) -> URL { journal.appending(path: id.uuidString + ".json") }

  func available() throws -> [TrashReceipt] {
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: journal, includingPropertiesForKeys: nil)
    } catch let e as CocoaError where e.code == .fileReadNoSuchFile { return [] }
    return files.filter { $0.pathExtension == "json" }.compactMap { url in
      guard let data = SmallMetadata.read(url),
        let r = try? JSONDecoder().decode(TrashReceipt.self, from: data)
      else { return nil }
      guard receiptsFile(r.id).path == url.path, owner(r.original, review: r.review, restoring: true) != nil else {
        return nil
      }
      let path = trash.appending(path: r.trashName)
      var s = stat()
      guard lstat(path.path, &s) == 0 else {
        if errno == ENOENT,
          (try? TrashFiles.directory(trash, enumerate: false, { _, info in info.st_dev }))
            == r.identity.device
        {
          // Another process may have journaled its intent and not yet performed the rename.
          let source = lstat(r.original.path, &s)
          let departed = source == 0 ? FileIdentity(s) != r.identity : errno == ENOENT
          if departed, lstat(path.path, &s) != 0, errno == ENOENT {
            try? FileManager.default.removeItem(at: url)
          }
        }
        return nil
      }
      return FileIdentity(s) == r.identity ? r : nil
    }.sorted { $0.date > $1.date }
  }

  func apply(_ confirmation: ConfirmedTrashPlan) async -> TrashOutcome {
    let plan = confirmation.plan
    var result = TrashOutcome(notices: plan.skipped)
    let uninstall = plan.applicationUninstall
    result.applicationUninstall = uninstall != nil
    if let uninstall {
      do {
        let policy = ScanExclusions(paths: plan.exclusions.map(\.path))
        guard plan.targets.first?.path.path == uninstall.app.path,
          plan.targets.allSatisfy({ $0.review?.applicationUninstall == uninstall && !policy.overlaps($0.path) })
        else { throw CleanupFailure("Review this item again.") }
        try uninstall.verifyBundle()
        if plan.targets.count > 1 {
          let installed = try await ApplicationUninstall.catalog(home: home, exclusions: plan.exclusions)
          guard await !uninstall.copiesInstalled(in: installed), plan.targets.dropFirst().allSatisfy({
            !uninstall.sharedData($0.path, home: home, installed: installed)
          }) else {
            throw CleanupFailure("Another installed application may use this file.")
          }
        }
      } catch {
        result.notices.append(error.localizedDescription)
        return result
      }
    }
    let before = await diskReading()
    // A simulator can have several separate cache roots. Refresh the state even in a long batch.
    var idle: (owner: Owner, time: ContinuousClock.Instant)?
    var removedBundle = false
    for target in plan.targets {
      if Task.isCancelled {
        result.notices.append(ReviewLanguage.text("İşlem durduruldu. Kalan hedefler taşınmadı."))
        break
      }
      do {
        if let uninstall, target.path.path != uninstall.app.path {
          var info = stat()
          guard removedBundle, lstat(uninstall.app.path, &info) != 0, errno == ENOENT else {
            result.notices.append(ReviewLanguage.text("Related files were kept because the application was not removed."))
            break
          }
        }
        try target.review?.ollama?.validate(target.path)
        if let duplicate = target.review?.duplicate {
          guard !plan.targets.contains(where: { $0.path.path == duplicate.survivor.path }) else {
            throw CleanupFailure("Keep at least one copy of every duplicate group.")
          }
          try duplicate.validate(target.path)
        }
        guard target.review?.inCurrentProjects(plan.projects) != false,
          let owner = owner(target.path, review: target.review) else {
          throw CleanupFailure("Hedef desteklenmiyor.")
        }
        let stamp = try TrashFiles.snapshot(
          target.path, on: target.snapshot.identity.device, allowSymlinks: owner == .xcode,
          download: target.review == nil ? owner.downloadCache : nil, review: target.review,
          development: owner.developmentCache, appCache: owner.isAppCache)
        var expected = target.snapshot
        if (target.review?.duplicate != nil && target.review?.duplicate?.original.mayShareBlocks != false)
          || (target.review?.ollama != nil && target.review?.ollama?.mayShareBlocks != false) {
          expected.sharedBytes = stamp.sharedBytes
        }
        guard stamp == expected else {
          throw CleanupFailure("Önizlemeden sonra değişti. Yeniden ölç.")
        }
        if owner.developmentCache != nil || owner == .xcode || owner == .ollama || owner == .package(.npm)
          || owner.downloadCache != nil || idle?.owner != owner
          || (idle?.time.duration(to: .now) ?? .seconds(2)) > .seconds(1)
        {
          try await verifyIdle(owner)
          idle = (owner, .now)
        }
        try verifyXcodeTarget(target, owner: owner, projects: plan.projects)
        try Task.checkCancellation()
        guard
          !ProjectAttribution.ProtectedProjects(plan.projects).containsProject(under: target.path)
        else {
          throw CleanupFailure("Seçili proje klasörünü içeriyor.")
        }
        let r = TrashReceipt(
          id: UUID(), original: target.path, parent: stamp.parent,
          identity: stamp.identity, bytes: stamp.bytes, date: .now, review: target.review,
          reclaimableBytes: target.review?.duplicate != nil || target.review?.ollama != nil ? target.snapshot.reclaimableBytes : stamp.reclaimableBytes)
        // Write the recoverable destination before the atomic move, including across app restarts.
        try FileManager.default.createDirectory(
          at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(r).write(to: receiptsFile(r.id), options: .atomic)
        let destination = trash.appending(path: r.trashName)
        do {
          try TrashFiles.move(
            target.path, to: destination, identity: r.identity,
            sourceParent: r.parent, destinationParent: nil, file: r.review?.file == true)
        } catch {
          var info = stat()
          if lstat(destination.path, &info) != 0, errno == ENOENT {
            try? FileManager.default.removeItem(at: receiptsFile(r.id))
          }
          throw error
        }
        // A writer may still have held an open descriptor while the directory was moved.
        // On a mismatch, restore only if the original name is still available.
        let sameProject = (try? verifyXcodeTarget(target, owner: owner, projects: plan.projects)) != nil
        let sameDuplicate = target.review?.duplicate.map { (try? $0.validate(destination)) != nil } ?? true
        let sameModel = target.review?.ollama.map { (try? $0.validate(destination)) != nil } ?? true
        var idleAfter = true
        if owner == .ollama { idleAfter = (try? await ollamaIdle()) == true }
        if case .appCache(let rule, let path) = owner {
          do {
            try await verifyIdle(.application(rule.bundle))
            try await developmentUse().verifyUnused([path, destination])
          } catch { idleAfter = false }
        }
        if let cache = owner.developmentCache {
          idleAfter = (try? await developmentUse().verify(cache, at: target.path, movedTo: destination)) != nil
          if idleAfter && cache == .orphanIntermediates {
            idleAfter = (try? await xcodeIdle()) == true
          }
        }
        let sameContents: Bool
        if sameProject && sameDuplicate && sameModel && idleAfter {
          let after = try? TrashFiles.snapshot(
            destination, on: r.identity.device, allowSymlinks: owner == .xcode,
            download: target.review == nil ? owner.downloadCache : nil, review: target.review,
            development: owner.developmentCache, appCache: owner.isAppCache)
          sameContents = after?.digest == stamp.digest
            && (owner.developmentCache != .orphanIntermediates || after?.sharedBytes == stamp.sharedBytes)
        } else {
          sameContents = false
        }
        if !sameContents {
          do {
            try TrashFiles.move(
              destination, to: target.path, identity: r.identity,
              sourceParent: nil, destinationParent: r.parent, file: r.review?.file == true)
          } catch {
            result.moved.append(r)
            throw CleanupFailure(
              ReviewLanguage.format("İçerik değişti. Otomatik geri alma tamamlanamadı: %@", error.localizedDescription))
          }
          try? FileManager.default.removeItem(at: receiptsFile(r.id))
          throw CleanupFailure("İçerik işlem sırasında değişti; klasör geri kondu.")
        }
        result.moved.append(r)
        if target.path.path == uninstall?.app.path { removedBundle = true }
      } catch { result.notices.append(target.path.path + " · " + error.localizedDescription) }
    }
    let movedPaths = Set(result.moved.map { $0.original.path })
    for (itemID, targets) in Dictionary(grouping: plan.targets, by: \.itemID) {
      if targets.allSatisfy({ movedPaths.contains($0.path.path) }) {
        result.completedItems.insert(itemID)
      }
    }
    result.diskAfter = await diskReading()
    if let a = before?.free, let b = result.diskAfter?.free {
      result.freeChange = b - a
    }
    return result
  }

  @discardableResult func restore(_ id: UUID) async throws -> TrashReceipt {
    let file = receiptsFile(id)
    guard let data = SmallMetadata.read(file),
      let r = try? JSONDecoder().decode(TrashReceipt.self, from: data),
      r.id == id, let owner = owner(r.original, review: r.review, restoring: true)
    else {
      throw CleanupFailure("Geri alma kaydı geçersiz.")
    }
    try Task.checkCancellation()
    try await verifyIdle(owner, restoring: true)
    try Task.checkCancellation()
    try TrashFiles.move(
      trash.appending(path: r.trashName), to: r.original, identity: r.identity,
      sourceParent: nil, destinationParent: r.parent, file: r.review?.file == true)
    // The original is already restored; stale journal entries are ignored by available().
    try? FileManager.default.removeItem(at: file)
    return r
  }
}
