import Darwin
import Foundation

package enum ScanGroup: String, CaseIterable, Sendable {
  case xcode = "Xcode derleme verileri"
  case simulators = "Simülatör cihazları"
  case packages = "Paket önbellekleri"
  case projects = "Seçili proje klasörleri"
  case logs = "Günlükler"
  case runtimes = "Simülatör runtime’ları"
  case tools = "Geliştirici araçları"
  case models = "AI modelleri ve araçları"
  case temp = "Geçici dosyalar"
  case docker = "Docker"
  case machines = "Sanal makineler"
  case trash = "Çöp"
  case backups = "Cihaz yedekleri"
  case shared = "Paylaşılan veriler"
  case android = "Android"
  case apps = "Uygulamalar ve medya"
  case system = "Sistem"
  case other = "Diğer büyük klasörler"
  case snapshots = "Time Machine"
}

package enum MeasurementSource: Hashable, Sendable {
  case directory, file
  case allocation(Int64)
  case report(Int64?)
  case status(String)
}

package struct ScanRoot: Identifiable, Hashable, Sendable {
  package let group: ScanGroup
  package let title: String
  package let url: URL
  package let profile: StorageProfile
  package let device: SimulatorDevice?
  package let source: MeasurementSource
  package var id: String {
    switch source {
    case .allocation, .report, .status: "\(group.rawValue)|\(url.path)|\(title)"
    default: "\(group.rawValue)|\(url.path)"
    }
  }

  package init(
    group: ScanGroup, title: String, url: URL, profile: StorageProfile = .unknown,
    device: SimulatorDevice? = nil, source: MeasurementSource = .directory
  ) {
    self.group = group
    self.title = title
    self.url = url
    self.profile = profile
    self.device = device
    self.source = source
  }

  package static func catalog(home: URL, projects: [URL]) -> [Self] {
    let caches: [(String, String, StorageProfile)] = [
      ("npm", ".npm/_cacache", .npmCache),
      ("SwiftPM", "Library/Caches/org.swift.swiftpm", .sharedDependencies),
      ("Homebrew", "Library/Caches/Homebrew", .packageDownloads),
      ("Yarn", "Library/Caches/Yarn", .packageDownloads),
      ("pnpm deposu", "Library/pnpm/store", .sharedDependencies),
      ("pip", "Library/Caches/pip", .packageDownloads),
      ("uv", ".cache/uv", .uvCache), ("uv (Library)", "Library/Caches/uv", .uvCache),
      ("CocoaPods", "Library/Caches/CocoaPods", .packageDownloads),
      ("Gradle", ".gradle/caches", .sharedDependencies),
      ("Go", "Library/Caches/go-build", .goBuildCache),
      ("Cargo kayıt deposu", ".cargo/registry", .sharedDependencies),
    ]
    return [
      Self(
        group: .xcode, title: "DerivedData",
        url: home.appending(path: "Library/Developer/Xcode/DerivedData"), profile: .xcodeWorkspace),
      Self(
        group: .logs, title: "Kullanıcı günlükleri", url: home.appending(path: "Library/Logs"),
        profile: .logs),
    ]
      + caches.map {
        Self(group: .packages, title: $0.0, url: home.appending(path: $0.1), profile: $0.2)
      }
      + projects.map {
        Self(group: .projects, title: $0.lastPathComponent, url: $0, profile: .project)
      }
  }
}

package struct FileKey: Hashable, Sendable {
  package let device: dev_t
  package let inode: ino_t
  package init(device: dev_t, inode: ino_t) {
    self.device = device
    self.inode = inode
  }
}

package enum ReadState: Equatable, Sendable {
  case complete, partial, absent
  case unavailable(String)
}

package struct RootSize: Sendable {
  package var bytes: Int64 = 0
  package var modified: Date?
  package var sourceModified: Date?
  package var lastBuild: Date?
  package var outputKinds: [String: Int64] = [:]
  package var measuredDevice: dev_t?
  package var simulatorCacheBytes: Int64 = 0
  package var sharedLinkBytes: Int64 = 0
  package var simulatorDataBytes: Int64 { bytes - simulatorCacheBytes }
  package var outputBytes: Int64 = 0
  package var files = 0
  package var missed = 0
  package var largest: [String: Int64] = [:]
  package var links: [FileKey: Int64] = [:]
  var simulatorCacheLinks = Set<FileKey>()
  package var state: ReadState = .complete

  package var measured: Bool { state == .complete || state == .partial }
}

package struct SafetyBreakdown: Equatable, Codable, Sendable {
  package let safe: Int64
  package let review: Int64
  package var total: Int64 { safe + review }
}

package struct GroupSize {
  package private(set) var breakdown: SafetyBreakdown?
  package var bytes: Int64? { breakdown?.total }
  private var links: [FileKey: (size: Int64, safe: Bool)] = [:]

  mutating func include(_ row: RootSize, for root: ScanRoot) throws {
    guard row.measured else { return }
    let safeRoot = root.device == nil && root.profile.assessment(for: row.state)?.level == .safe
    let splitDevice =
      root.device != nil && StorageProfile.simulatorCache.assessment(for: row.state)?.level == .safe
    var safe = safeRoot ? row.bytes : (splitDevice ? row.simulatorCacheBytes : 0)
    var review = row.bytes - safe
    for (key, size) in row.links {
      try Task.checkCancellation()
      let isSafe = safeRoot || (splitDevice && row.simulatorCacheLinks.contains(key))
      if let previous = links[key] {
        // Replace both observations with one. A link shared with Review belongs
        // to Review regardless of visit order, even across quick/extended batches.
        if isSafe { safe -= size } else { review -= size }
        if previous.safe { safe -= previous.size } else { review -= previous.size }
        let sharedSize = max(previous.size, size)
        let sharedSafe = previous.safe && isSafe
        if sharedSafe { safe += sharedSize } else { review += sharedSize }
        links[key] = (sharedSize, sharedSafe)
      } else {
        links[key] = (size, isSafe)
      }
    }
    breakdown = .init(
      safe: (breakdown?.safe ?? 0) + safe, review: (breakdown?.review ?? 0) + review)
  }
}

package enum StorageMeter {
  package static let outputFolders: Set<String> = [
    "node_modules", ".build", "DerivedData", "Pods", ".next", ".nuxt", ".svelte-kit",
    ".astro", ".angular", ".turbo", ".parcel-cache", ".expo",
  ]

  @concurrent package static func scan(
    _ roots: [ScanRoot], startingWith groupsSoFar: [ScanGroup: GroupSize] = [:],
    cache: MeasurementCache? = nil,
    onStart: @MainActor @Sendable (ScanRoot) -> Void,
    onFinish: @MainActor @Sendable (ScanRoot, RootSize, Int64?) -> Void
  ) async throws -> [ScanGroup: GroupSize] {
    var groups = groupsSoFar
    for root in roots {
      try Task.checkCancellation()
      await onStart(root)
      let ticket = await cache?.ticket(root)
      var row: RootSize
      if let saved = await cache?.cached(root, ticket) {
        row = saved
      } else {
        row = try await measure(root)
        if ticket != nil { await cache?.store(row, for: root, before: ticket) }
      }
      if root.group != .other || row.state != .complete || row.bytes >= 500 * 1024 * 1024 {
        try groups[root.group, default: GroupSize()].include(row, for: root)
      }
      row.sharedLinkBytes = row.links.values.reduce(0, +)
      row.links.removeAll()
      row.simulatorCacheLinks.removeAll()
      try Task.checkCancellation()
      await onFinish(root, row, groups[root.group]?.bytes)
    }
    return groups
  }

  /// Only opens directories. File sizes come from metadata; file contents are never opened.
  @concurrent package static func measure(_ root: ScanRoot) async throws -> RootSize {
    try Task.checkCancellation()
    switch root.source {
    case .allocation(let bytes): return RootSize(bytes: bytes)
    case .status(let message): return RootSize(state: .unavailable(message))
    case .report(let bytes):
      return bytes.map { RootSize(bytes: $0) }
        ?? RootSize(state: .unavailable("Araç boyut bildirmiyor"))
    case .file:
      var info = stat()
      // Inspect only metadata. O_EVTONLY avoids reading or materialising the file.
      let fd = open(root.url.path, O_EVTONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else {
        return RootSize(state: errno == ENOENT ? .absent : .unavailable("Dosya okunamadı"))
      }
      defer { close(fd) }
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        return RootSize(state: .unavailable("Normal dosya değil"))
      }
      let bytes = max(0, Int64(info.st_blocks)) * 512
      var row = RootSize(
        bytes: bytes, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
        measuredDevice: info.st_dev, files: 1)
      if info.st_nlink > 1 { row.links[FileKey(device: info.st_dev, inode: info.st_ino)] = bytes }
      return row
    case .directory: break
    }
    let fd = open(root.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else {
      let failure = errno
      let reason: String
      switch failure {
      case EACCES, EPERM: reason = "Erişim izni yok"
      case ELOOP: reason = "Sembolik bağlantı izlenmedi"
      case ENOTDIR: reason = "Konum bir klasör değil veya yol bir bağlantı içeriyor"
      case ENOENT:
        return RootSize(
          state: (root.group == .projects || root.group == .simulators)
            ? .unavailable("Klasöre ulaşılamıyor") : .absent)
      default: reason = "Konum okunamadı"
      }
      return RootSize(state: .unavailable(reason))
    }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      close(fd)
      return RootSize(state: .unavailable("Klasör bilgisi okunamadı"))
    }
    var walk = Walk(device: info.st_dev, project: root.group == .projects)
    walk.result.measuredDevice = info.st_dev
    let output =
      root.group == .projects && outputFolders.contains(root.url.lastPathComponent)
      ? root.url.lastPathComponent : nil
    try walk.visit(
      fd, level: 0, branch: "", output: output, sourceTree: true,
      scope: root.group == .simulators ? .device : .other)
    // A cache file also linked from Documents, another device, or an
    // unreadable location belongs to the review side of the split.
    for (key, links) in walk.cacheLinks {
      try Task.checkCancellation()
      if links.seen == links.expected {
        walk.result.simulatorCacheBytes += walk.result.links[key] ?? 0
        walk.result.simulatorCacheLinks.insert(key)
      }
    }
    if walk.result.missed > 0 && walk.result.state == .complete { walk.result.state = .partial }
    return walk.result
  }

  private struct Walk {
    let device: dev_t
    let project: Bool
    var result = RootSize()
    var outputLinks = Set<FileKey>()
    var cacheLinks: [FileKey: (seen: Int, expected: Int)] = [:]

    /// Takes ownership of fd, even if enumeration fails or is cancelled.
    mutating func visit(
      _ fd: Int32, level: Int, branch: String, output: String?, sourceTree: Bool,
      scope: SimulatorDirectory
    ) throws {
      guard let dir = fdopendir(fd) else {
        close(fd)
        result.missed += 1
        if level == 0 { result.state = .unavailable("Klasör listelenemedi") }
        return
      }
      defer { closedir(dir) }
      while true {
        try Task.checkCancellation()
        errno = 0
        guard let entry = readdir(dir) else {
          if errno != 0 { result.missed += 1 }
          break
        }
        try withUnsafePointer(to: &entry.pointee.d_name) { nameStorage in
          try nameStorage.withMemoryRebound(
            to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1
          ) { name in
            if strcmp(name, ".") == 0 || strcmp(name, "..") == 0 { return }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
              result.missed += 1
              return
            }
            guard info.st_dev == device else { return }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { return }
            let needsName =
              level == 0
              || (type == S_IFDIR && ((project && output == nil) || scope.checksChildName))
            let childName = needsName ? String(cString: name) : ""
            let bucket = level == 0 ? (type == S_IFDIR ? childName : "Kök dosyaları") : branch
            if type == S_IFDIR {
              guard level < 160 else {
                result.missed += 1
                return
              }
              let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
              guard child >= 0 else {
                result.missed += 1
                return
              }
              var opened = stat()
              guard fstat(child, &opened) == 0, opened.st_dev == device,
                opened.st_ino == info.st_ino
              else {
                close(child)
                result.missed += 1
                return
              }
              try visit(
                child, level: level + 1, branch: bucket,
                output: output
                  ?? (project && StorageMeter.outputFolders.contains(childName) ? childName : nil),
                sourceTree: sourceTree && childName != ".git",
                scope: scope.descending(into: childName))
              return
            }
            let bytes = max(0, Int64(info.st_blocks)) * 512
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            if modified > (result.modified ?? .distantPast) { result.modified = modified }
            if project {
              if output != nil && modified > (result.lastBuild ?? .distantPast) {
                result.lastBuild = modified
              }
              if output == nil && sourceTree && modified > (result.sourceModified ?? .distantPast) {
                result.sourceModified = modified
              }
            }
            if info.st_nlink > 1 {
              let key = FileKey(device: info.st_dev, inode: info.st_ino)
              if scope == .cache {
                let previous = cacheLinks[key] ?? (0, 0)
                cacheLinks[key] = (previous.seen + 1, max(previous.expected, Int(info.st_nlink)))
              }
              if let output, outputLinks.insert(key).inserted {
                result.outputBytes += bytes
                result.outputKinds[output, default: 0] += bytes
              }
              guard result.links[key] == nil else { return }
              result.links[key] = bytes
            } else {
              if scope == .cache { result.simulatorCacheBytes += bytes }
              if let output {
                result.outputBytes += bytes
                result.outputKinds[output, default: 0] += bytes
              }
            }
            result.files += 1
            result.bytes += bytes
            result.largest[bucket, default: 0] += bytes
          }
        }
      }
    }
  }
}

package struct VolumeReading: Sendable {
  package let name: String
  package let bytes: Int64
  package let free: Int64
  package init(name: String, bytes: Int64, free: Int64) {
    self.name = name
    self.bytes = bytes
    self.free = free
  }

  @concurrent package static func read(at url: URL) async -> Self? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
      ]),
      let capacity = values.volumeTotalCapacity, capacity > 0,
      let free = values.volumeAvailableCapacity
    else { return nil }
    return Self(
      name: values.volumeName ?? "Depolama birimi", bytes: Int64(capacity), free: Int64(free))
  }
}
