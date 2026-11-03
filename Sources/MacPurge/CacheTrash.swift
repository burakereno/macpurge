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
  let snapshot: CacheSnapshot
  var id: String { path.path }
}

struct TrashPlan: Identifiable, Sendable {
  let id = UUID()
  let reportID: UUID
  var targets: [TrashTarget] = []
  var skipped: [String] = []
}

struct TrashReceipt: Identifiable, Codable, Sendable {
  let id: UUID
  let original: URL
  let parent: FileIdentity
  let identity: FileIdentity
  let bytes: Int64
  let date: Date
  var trashName: String { original.lastPathComponent + " (MacPurge " + id.uuidString + ")" }
}

struct TrashOutcome: Sendable {
  let id = UUID()
  var moved: [TrashReceipt] = []
  var completedItems: Set<String> = []
  var notices: [String] = []
  var freeChange: Int64?
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

/// Authorization is derived from known local cache roots, never from a saved report's label alone.
actor CacheTrash {
  static let userTrash =
    (try? FileManager.default.url(
      for: .trashDirectory, in: .userDomainMask,
      appropriateFor: FileManager.default.homeDirectoryForCurrentUser, create: false))
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
  static let shared = CacheTrash(
    home: FileManager.default.homeDirectoryForCurrentUser,
    journal: URL.applicationSupportDirectory.appending(path: "MacPurge/TrashReceipts"),
    trash: userTrash)
  let home: URL
  let journal: URL
  private let deviceIsShutdown: @Sendable (UUID) async throws -> Bool
  private let trash: URL

  init(
    home: URL, journal: URL, trash: URL? = nil,
    deviceIsShutdown: @escaping @Sendable (UUID) async throws -> Bool = CacheTrash.deviceIsShutdown
  ) {
    self.home = home
    self.journal = journal
    self.trash = trash ?? home.appending(path: ".Trash")
    self.deviceIsShutdown = deviceIsShutdown
  }

  private enum Owner: Equatable {
    case package
    case application(String)
    case simulator(UUID)
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

  private func owner(_ path: URL) -> Owner? {
    guard let p = parts(path) else { return nil }
    if p == [".npm", "_cacache"] || p == ["Library", "Caches", "go-build"] { return .package }
    if p.count == 4, p[0] == "Library", p[1] == "Application Support",
      RenderCacheOwner.leaves.contains(p[3]),
      let app = RenderCacheOwner.all.first(where: { $0.folder == p[2] })
    {
      return .application(app.bundle)
    }
    guard let device = simulator(p) else { return nil }
    var scope = SimulatorDirectory.device
    for component in p.dropFirst(5) {
      if scope == .cache { return nil }  // only the cache boundary itself is a target
      scope = scope.descending(into: component)
    }
    return scope == .cache ? .simulator(device) : nil
  }

  static func deviceIsShutdown(_ id: UUID) async throws -> Bool {
    struct Inventory: Decodable {
      struct Device: Decodable {
        let udid: String
        let state: String
      }
      let devices: [String: [Device]]
    }
    let data = try await InventoryCommand.output(
      "/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
    let devices = try JSONDecoder().decode(Inventory.self, from: data).devices.values.joined()
    return devices.first(where: { UUID(uuidString: $0.udid) == id })?.state == "Shutdown"
  }

  private func verifyIdle(_ owner: Owner) async throws {
    switch owner {
    case .package: break
    case .application(let bundle):
      if await MainActor.run(body: {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
      }) {
        throw CleanupFailure("Uygulamayı kapatıp yeniden dene.")
      }
    case .simulator(let id):
      guard try await deviceIsShutdown(id) else {
        throw CleanupFailure("Simülatörün kapalı olduğu doğrulanamadı.")
      }
    }
  }

  private func locations(_ row: ReportItem) async throws -> [URL] {
    let root = URL(fileURLWithPath: row.path)
    guard row.complete, row.safety == SafetyLevel.safe.rawValue, row.eligibleBytes > 0,
      row.basis == "allocated"
    else { throw CleanupFailure("Tam ölçülmüş bir Güvenli öğe değil.") }
    if let owner = owner(root) {
      switch (owner, ScanGroup(rawValue: row.category)) {
      case (.package, .packages), (.application, .apps): break
      default: throw CleanupFailure("Öğe bu kategoriden taşınamaz.")
      }
      try await verifyIdle(owner)
      return [root]
    }
    guard let p = parts(root), p.count == 5, let id = simulator(p),
      row.category == ScanGroup.simulators.rawValue
    else {
      throw CleanupFailure("Bu konumda uygulama içinden işlem desteklenmiyor.")
    }
    try await verifyIdle(.simulator(id))
    let apps = root.appending(path: "data/Containers/Data/Application")
    var bases = [root.appending(path: "data")]
    do {
      bases += try DirectoryIndex.children(of: apps).filter {
        $0.directory && UUID(uuidString: $0.url.lastPathComponent) != nil
      }.map(\.url)
    } catch let error as DirectoryIndex.Problem where error.code == ENOENT {}
    return bases.flatMap { base in ["Library/Caches", "tmp"].map { base.appending(path: $0) } }
  }

  func prepare(items: [ReportItem], reportID: UUID, projects: [URL]) async -> TrashPlan {
    var plan = TrashPlan(reportID: reportID)
    var seen = Set<String>()
    for row in items {
      do {
        let paths = try await locations(row)
        guard let device = row.volume,
          try TrashFiles.directory(home, { _, s in s.st_dev }) == device
        else { throw CleanupFailure("Ölçülen disk değişti.") }
        var found = false
        for path in paths {
          try Task.checkCancellation()
          guard owner(path) != nil else { throw CleanupFailure("Hedef yolu doğrulanamadı.") }
          guard
            !projects.contains(where: { $0.path == path.path || $0.path.hasPrefix(path.path + "/") }
            )
          else { throw CleanupFailure("Seçili proje klasörünü içeriyor.") }
          do {
            let stamp = try TrashFiles.snapshot(path, on: device)
            guard stamp.bytes > 0 else { continue }
            found = true
            if seen.insert(path.path).inserted {
              plan.targets.append(
                .init(itemID: row.id, name: row.name, path: path, snapshot: stamp))
            }
          } catch let error as POSIXError where error.code == .ENOENT { continue }
        }
        if !found { throw CleanupFailure("Taşınabilecek ölçülmüş önbellek bulunamadı.") }
      } catch { plan.skipped.append(row.name + " · " + error.localizedDescription) }
    }
    return plan
  }

  private func receiptsFile(_ id: UUID) -> URL { journal.appending(path: id.uuidString + ".json") }

  func available() throws -> [TrashReceipt] {
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: journal, includingPropertiesForKeys: nil)
    } catch let e as CocoaError where e.code == .fileReadNoSuchFile { return [] }
    return try files.filter { $0.pathExtension == "json" }.compactMap { url in
      let r = try JSONDecoder().decode(TrashReceipt.self, from: Data(contentsOf: url))
      guard receiptsFile(r.id).path == url.path, owner(r.original) != nil else { return nil }
      let path = trash.appending(path: r.trashName)
      var s = stat()
      guard lstat(path.path, &s) == 0 else {
        if errno == ENOENT { return nil }
        throw TrashFiles.posix()
      }
      return FileIdentity(s) == r.identity ? r : nil
    }.sorted { $0.date > $1.date }
  }

  func apply(_ plan: TrashPlan) async -> TrashOutcome {
    var result = TrashOutcome(notices: plan.skipped)
    let before = await VolumeReading.read(at: home)
    // A simulator can have several separate cache roots. Refresh the state even in a long batch.
    var idle: (owner: Owner, time: ContinuousClock.Instant)?
    for target in plan.targets {
      if Task.isCancelled {
        result.notices.append(ReviewLanguage.text("İşlem durduruldu. Kalan hedefler taşınmadı."))
        break
      }
      do {
        guard let owner = owner(target.path) else { throw CleanupFailure("Hedef desteklenmiyor.") }
        let stamp = try TrashFiles.snapshot(target.path, on: target.snapshot.identity.device)
        guard stamp == target.snapshot else {
          throw CleanupFailure("Önizlemeden sonra değişti. Yeniden ölç.")
        }
        if idle?.owner != owner || (idle?.time.duration(to: .now) ?? .seconds(2)) > .seconds(1) {
          try await verifyIdle(owner)
          idle = (owner, .now)
        }
        try Task.checkCancellation()
        let r = TrashReceipt(
          id: UUID(), original: target.path, parent: stamp.parent,
          identity: stamp.identity, bytes: stamp.bytes, date: .now)
        // Write the recoverable destination before the atomic move, including across app restarts.
        try FileManager.default.createDirectory(
          at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(r).write(to: receiptsFile(r.id), options: .atomic)
        let destination = trash.appending(path: r.trashName)
        do {
          try TrashFiles.move(
            target.path, to: destination, identity: r.identity,
            sourceParent: r.parent, destinationParent: nil)
        } catch {
          var info = stat()
          if lstat(destination.path, &info) != 0, errno == ENOENT {
            try? FileManager.default.removeItem(at: receiptsFile(r.id))
          }
          throw error
        }
        // A writer may still have held an open descriptor while the directory was moved.
        // On a mismatch, restore only if the original name is still available.
        if (try? TrashFiles.snapshot(destination, on: r.identity.device))?.digest != stamp.digest {
          do {
            try TrashFiles.move(
              destination, to: target.path, identity: r.identity,
              sourceParent: nil, destinationParent: r.parent)
          } catch {
            result.moved.append(r)
            throw CleanupFailure(
              "İçerik değişti. Otomatik geri alma tamamlanamadı: " + error.localizedDescription)
          }
          try? FileManager.default.removeItem(at: receiptsFile(r.id))
          throw CleanupFailure("İçerik işlem sırasında değişti; klasör geri kondu.")
        }
        result.moved.append(r)
      } catch { result.notices.append(target.path.path + " · " + error.localizedDescription) }
    }
    let movedPaths = Set(result.moved.map { $0.original.path })
    for (itemID, targets) in Dictionary(grouping: plan.targets, by: \.itemID) {
      if targets.allSatisfy({ movedPaths.contains($0.path.path) }) {
        result.completedItems.insert(itemID)
      }
    }
    if let a = before?.free, let b = await VolumeReading.read(at: home)?.free {
      result.freeChange = b - a
    }
    return result
  }

  func restore(_ id: UUID) async throws {
    let file = receiptsFile(id)
    let r = try JSONDecoder().decode(TrashReceipt.self, from: Data(contentsOf: file))
    guard r.id == id, let owner = owner(r.original) else {
      throw CleanupFailure("Geri alma kaydı geçersiz.")
    }
    try await verifyIdle(owner)
    try TrashFiles.move(
      trash.appending(path: r.trashName), to: r.original, identity: r.identity,
      sourceParent: nil, destinationParent: r.parent)
    // The original is already restored; stale journal entries are ignored by available().
    try? FileManager.default.removeItem(at: file)
  }
}
