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
  package let runtimeUsage: RuntimeUsage?
  package let workspace: String?
  package var projectOwner: String? = nil
  package var expectedDevice: dev_t? = nil
  package var downloadCache: PackageDownloadCache? = nil

  package func effectiveProfile(_ size: RootSize?) -> StorageProfile {
    size?.unexpectedDownloads == true ? .unrecognizedDownloads : profile
  }
  package func includedInInventory(_ size: RootSize) -> Bool {
    group != .other || size.state != .complete || size.bytes >= 500 * 1024 * 1024
  }
  // Relative paths whose contribution can be replaced after a confirmed rename.
  // A single "*" component matches a simulator container. "{receipt}" matches our own Trash names.
  package var cleanupPatterns = Set<String>()
  package var caseInsensitiveCleanup = false
  package func cleanupKey(_ path: String) -> String {
    caseInsensitiveCleanup ? path.lowercased() : path
  }
  // Relative subtrees or files measured by a more specific inventory root.
  package var excludedDirectories: Set<String> = []
  package var containsScanExclusions = false
  package let source: MeasurementSource
  package var displayTitle: String {
    profile == .xcodeWorkspace && !excludedDirectories.isEmpty
      ? "DerivedData · diğer içerik" : title
  }
  package var id: String {
    switch source {
    case .allocation, .report, .status: "\(group.rawValue)|\(url.path)|\(title)"
    default: "\(group.rawValue)|\(url.path)"
    }
  }

  package init(
    group: ScanGroup, title: String, url: URL, profile: StorageProfile = .unknown,
    device: SimulatorDevice? = nil, source: MeasurementSource = .directory,
    workspace: String? = nil, runtimeUsage: RuntimeUsage? = nil
  ) {
    self.group = group
    self.title = title
    self.url = url
    self.profile = profile
    self.device = device
    self.runtimeUsage = runtimeUsage
    self.workspace = workspace
    self.source = source
  }

  package static func catalog(home: URL, projects: [URL]) -> [Self] {
    let caches: [(String, String, StorageProfile)] = [
      ("npm", ".npm/_cacache", .npmCache),
      ("SwiftPM", "Library/Caches/org.swift.swiftpm", .sharedDependencies),
      ("Homebrew · diğer içerik", "Library/Caches/Homebrew", .packageDownloads),
      ("Yarn", "Library/Caches/Yarn", .packageDownloads),
      ("pnpm deposu", "Library/pnpm/store", .sharedDependencies),
      ("pip · diğer içerik", "Library/Caches/pip", .packageDownloads),
      ("uv", ".cache/uv", .uvCache), ("uv (Library)", "Library/Caches/uv", .uvCache),
      ("CocoaPods", "Library/Caches/CocoaPods", .packageDownloads),
      ("Gradle", ".gradle/caches", .gradleCache),
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
        title, path, profile in
        var root = Self(
          group: .packages, title: title, url: home.appending(path: path), profile: profile)
        root.excludedDirectories = Set(
          PackageDownloadCache.allCases.compactMap { cache in
            let prefix = path + "/"
            return cache.rawValue.hasPrefix(prefix)
              ? String(cache.rawValue.dropFirst(prefix.count)) : nil
          })
        return root
      }
      + PackageDownloadCache.allCases.map { cache in
        var root = Self(
          group: .packages, title: cache.title, url: home.appending(path: cache.rawValue),
          profile: .verifiedDownloads)
        root.downloadCache = cache
        return root
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

package struct FileAgeBreakdown: Codable, Hashable, Sendable {
  package var recent: Int64 = 0
  package var older: Int64 = 0
}

/// A compact record of a cleanup boundary, obtained during the ordinary directory walk.
package struct DirectoryReading: Sendable {
  package let device: dev_t
  package let inode: ino_t
  package let seconds: Int
  package let nanos: Int
  package var bytes: Int64
  package var files: Int
  package var verified: Bool

  init(_ info: stat, bytes: Int64, files: Int, verified: Bool) {
    device = info.st_dev
    inode = info.st_ino
    seconds = info.st_ctimespec.tv_sec
    nanos = info.st_ctimespec.tv_nsec
    self.bytes = bytes
    self.files = files
    self.verified = verified
  }
}

package struct BranchReading: Sendable {
  var bucket: String?
  package var bytes: Int64 = 0
  package var files: Int = 0
  package var outputKinds: [String: Int64] = [:]
  package var modified: Date?
  package var sourceModified: Date?
  package var lastBuild: Date?

  mutating func observe(_ date: Date, output: String?, source: Bool) {
    if date > (modified ?? .distantPast) { modified = date }
    if output != nil && date > (lastBuild ?? .distantPast) { lastBuild = date }
    if source && output == nil && date > (sourceModified ?? .distantPast) { sourceModified = date }
  }
}

package struct RootSize: Sendable {
  package var branches: [String: BranchReading] = [:]
  package var baselineDates = BranchReading()
  // Retain identities only for the five directory details the overview can display.
  package var detailDirectories: [String: DirectoryReading] = [:]

  mutating func recordDetail(_ name: String, _ reading: DirectoryReading) {
    guard reading.bytes > 0 else { return }
    if detailDirectories[name] == nil, detailDirectories.count == 5,
      let smallest = detailDirectories.min(by: { a, b in
        a.value.bytes != b.value.bytes ? a.value.bytes < b.value.bytes : a.key > b.key
      })
    {
      guard
        reading.bytes > smallest.value.bytes
          || (reading.bytes == smallest.value.bytes && name < smallest.key)
      else { return }
      detailDirectories.removeValue(forKey: smallest.key)
    }
    detailDirectories[name] = reading
  }

  package var cleanupReadings: [String: DirectoryReading] = [:]
  package var age: FileAgeBreakdown?
  package var unexpectedDownloads = false
  package var bytes: Int64 = 0
  package var modified: Date?
  package var sourceModified: Date?
  package var lastBuild: Date?
  package var outputKinds: [String: Int64] = [:]
  package var measuredInode: ino_t?
  package var measuredDevice: dev_t?
  package var simulatorCacheBytes: Int64 = 0
  package var sharedLinkBytes: Int64 = 0
  package var simulatorDataBytes: Int64 { bytes - simulatorCacheBytes }
  // Overlap with earlier partitions of the same project during this scan.
  package var projectOverlapBytes: Int64 = 0
  package var projectHadLinks = false
  package var approximateProjectSize = false
  package var outputBytes: Int64 = 0
  package var files = 0
  package var missed = 0
  package var largest: [String: Int64] = [:]
  // Extra occurrences were omitted from largest to avoid double-counting the project.
  package var duplicateBytesByBranch: [String: Int64] = [:]
  var linkChecks: [FileKey: LinkCheck] = [:]
  package var links: [FileKey: Int64] = [:]
  var simulatorCacheLinks = Set<FileKey>()
  package var state: ReadState = .complete

  private(set) var topEntries: [(key: String, value: Int64)]?
  package mutating func finishBreakdown() {
    topEntries = nil
    topEntries = largestFive
  }

  package var largestFive: [(key: String, value: Int64)] {
    if let topEntries { return topEntries }
    var best: [(key: String, value: Int64)] = []
    for entry in largest {
      let index =
        best.firstIndex {
          entry.value > $0.value || (entry.value == $0.value && entry.key < $0.key)
        } ?? best.count
      guard index < 5 else { continue }
      best.insert(entry, at: index)
      if best.count > 5 { best.removeLast() }
    }
    return best
  }

  package static var incomplete: Self { RootSize(state: .partial) }

  /// Replace one isolated physical subtree. All sibling bytes, including any duplicate
  /// allocations there, keep their last full measurement.
  package mutating func replaceBranch(
    _ path: String, in root: ScanRoot, with fresh: RootSize, previously old: RootSize? = nil,
    file: Bool = false
  ) {
    let relative = path.dropFirst(root.url.path == "/" ? 1 : root.url.path.count + 1).split(
      separator: "/")
    guard let first = relative.first else { return }
    let key = root.cleanupKey(path)
    let directFile = file && relative.count == 1
    let fromPrior = old.map { size in
      BranchReading(
        bytes: size.bytes, files: size.files, outputKinds: size.outputKinds,
        modified: size.modified, sourceModified: size.sourceModified, lastBuild: size.lastBuild)
    }
    let detail = relative.count == 1 ? detailDirectories.removeValue(forKey: String(first)) : nil
    let fromDetail = detail.map {
      BranchReading(bucket: String(first), bytes: $0.bytes, files: $0.files)
    }
    let previous = branches.removeValue(forKey: key) ?? fromPrior ?? fromDetail ?? BranchReading()
    let bucket = previous.bucket ?? (directFile ? "Kök dosyaları" : String(first))
    var next = BranchReading(bucket: bucket)
    if fresh.measured {
      next.bytes = max(0, fresh.bytes - fresh.sharedLinkBytes)
      next.files = fresh.files
      next.modified = fresh.modified
      if root.group == .projects {
        let context = [root.url.lastPathComponent] + relative.map(String.init)
        if let output = context.first(where: StorageMeter.outputFolders.contains) {
          next.outputKinds = [output: fresh.bytes]
          next.lastBuild = fresh.modified
        } else {
          next.outputKinds = fresh.outputKinds
          next.lastBuild = fresh.lastBuild
          next.sourceModified = context.contains(".git") ? nil : fresh.sourceModified
        }
      }
      branches[key] = next
    }
    let delta = next.bytes - previous.bytes
    bytes = max(0, bytes + delta)
    files = max(0, files + next.files - previous.files)
    let branchBytes = (largest[bucket] ?? 0) + delta
    largest[bucket] = branchBytes > 0 ? branchBytes : nil
    for (kind, bytes) in previous.outputKinds { outputKinds[kind, default: 0] -= bytes }
    for (kind, bytes) in next.outputKinds { outputKinds[kind, default: 0] += bytes }
    outputKinds = outputKinds.filter { $0.value > 0 }
    outputBytes = outputKinds.values.reduce(0, +)
    if root.device != nil { simulatorCacheBytes = min(bytes, max(0, simulatorCacheBytes + delta)) }
    if relative.count == 1, !file, let reading = fresh.cleanupReadings[path] {
      recordDetail(String(first), reading)
    }
    cleanupReadings[path] = fresh.cleanupReadings[path]
    if fresh.state != .absent && (fresh.state != .complete || fresh.sharedLinkBytes > 0) {
      state = .partial
    }
  }

  package mutating func finishBranches() {
    modified = baselineDates.modified
    lastBuild = baselineDates.lastBuild
    sourceModified = baselineDates.sourceModified
    for branch in branches.values {
      if let d = branch.modified, d > (modified ?? .distantPast) { modified = d }
      if let d = branch.lastBuild, d > (lastBuild ?? .distantPast) { lastBuild = d }
      if let d = branch.sourceModified, d > (sourceModified ?? .distantPast) { sourceModified = d }
    }
    finishBreakdown()
  }

  package mutating func releaseLinkIndex() {
    links.removeAll()
    simulatorCacheLinks.removeAll()
    linkChecks.removeAll()
  }

  package var measured: Bool { state == .complete || state == .partial }
}

package struct SafetyBreakdown: Equatable, Codable, Sendable {
  package let safe: Int64
  package let review: Int64
  package var total: Int64 { safe + review }
}

package struct GroupSize: Sendable {
  package init() {}
  package private(set) var breakdown: SafetyBreakdown?
  package var bytes: Int64? { breakdown?.total }
  private var links: [FileKey: (size: Int64, safe: Bool)] = [:]

  package func applyingPreviousOverlap(
    raw: SafetyBreakdown?, deduplicated: SafetyBreakdown?, uncertain: Int64
  ) -> SafetyBreakdown? {
    guard let breakdown else { return nil }
    let safeOverlap = max(0, (raw?.safe ?? 0) - (deduplicated?.safe ?? raw?.safe ?? 0))
    let reviewOverlap = max(0, (raw?.review ?? 0) - (deduplicated?.review ?? raw?.review ?? 0))
    let safe = max(0, breakdown.safe - safeOverlap)
    return SafetyBreakdown(
      safe: max(0, safe - uncertain),
      review: max(0, breakdown.review - reviewOverlap - max(0, uncertain - safe)))
  }

  package mutating func include(_ row: RootSize, for root: ScanRoot) throws {
    guard row.measured else { return }
    let safeRoot =
      root.device == nil && root.effectiveProfile(row).assessment(for: row.state)?.level == .safe
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
    let roots = roots.compactMap(ScanExclusions.current.applying)
    var groups = groupsSoFar
    var remaining = Dictionary(grouping: roots.filter { $0.group == .projects },
      by: { $0.projectOwner ?? $0.url.path }).mapValues(\.count)
    var projectLinks: [String: Set<FileKey>] = [:]
    for root in roots {
      try Task.checkCancellation()
      await onStart(root)
      let ticket = await cache?.ticket(root)
      var row: RootSize
      if let saved = await cache?.cached(root, ticket) {
        row = saved
      } else {
        row = try await measure(root, trackLinks: ticket != nil)
        if ticket != nil { await cache?.store(row, for: root, before: ticket) }
      }
      if root.includedInInventory(row) {
        try groups[root.group, default: GroupSize()].include(row, for: root)
      }
      if root.group == .projects {
        row.projectHadLinks = !row.links.isEmpty
        let owner = root.projectOwner ?? root.url.path
        if remaining[owner, default: 0] > 1 || projectLinks[owner] != nil {
          for (key, bytes) in row.links where !projectLinks[owner, default: []].insert(key).inserted {
            row.projectOverlapBytes += bytes
          }
        }
        remaining[owner, default: 1] -= 1
        if remaining[owner] == 0 { projectLinks.removeValue(forKey: owner) }
      }
      row.releaseLinkIndex()
      try Task.checkCancellation()
      await onFinish(root, row, groups[root.group]?.bytes)
    }
    return groups
  }

  /// Only opens directories. File sizes come from metadata; file contents are never opened.
  @concurrent package static func measure(
    _ root: ScanRoot, at date: Date = .now, trackLinks: Bool = false, projectDetails: Bool = false,
    inspectCleanup: Bool = false
  ) async throws
    -> RootSize
  {
    try Task.checkCancellation()
    guard let root = ScanExclusions.current.applying(to: root) else { return RootSize(state: .absent) }
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
      if let expected = root.expectedDevice, info.st_dev != expected {
        return RootSize(state: .unavailable("Farklı disk"))
      }
      let bytes = max(0, Int64(info.st_blocks)) * 512
      var row = RootSize(
        bytes: bytes, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
        measuredInode: info.st_ino, measuredDevice: info.st_dev, files: 1)
      if info.st_nlink > 1 {
        row.links[FileKey(device: info.st_dev, inode: info.st_ino)] = bytes
        row.sharedLinkBytes = bytes
      }
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
          state: ((root.group == .projects && !root.profile.isProjectOutput) || root.group == .simulators)
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
    if let expected = root.expectedDevice, info.st_dev != expected {
      close(fd)
      return RootSize(state: .unavailable("Farklı disk"))
    }
    var walk = Walk(
      caseInsensitiveCleanup: root.caseInsensitiveCleanup,
      captureBranches: !root.cleanupPatterns.isEmpty, rootPath: root.url.path,
      safeRoot: inspectCleanup || root.profile.assessment(for: .complete)?.level == .safe,
      projectOutput: root.profile == .projectOutput, allowSymlinks: root.profile == .xcodeIntermediate,
      trackLinks: trackLinks, device: info.st_dev,
      project: root.group == .projects || projectDetails,
      download: root.downloadCache,
      ageCutoff: root.group == .temp ? date.addingTimeInterval(-72 * 3600) : nil)
    if root.group == .temp { walk.result.age = FileAgeBreakdown() }
    walk.result.measuredInode = info.st_ino
    walk.result.measuredDevice = info.st_dev
    let output =
      (projectDetails || root.group == .projects)
        && outputFolders.contains(root.url.lastPathComponent)
      ? root.url.lastPathComponent : nil
    try walk.visit(
      fd, level: 0, branch: "", output: output, sourceTree: true,
      scope: root.group == .simulators ? .device : .other,
      exclusions: root.excludedDirectories.map { $0.split(separator: "/")[...] },
      patterns: root.cleanupPatterns.map { $0.split(separator: "/")[...] })
    // A cache file also linked from Documents, another device, or an
    // unreadable location belongs to the review side of the split.
    for (key, links) in walk.cacheLinks {
      try Task.checkCancellation()
      if links.seen == links.expected {
        walk.result.simulatorCacheBytes += walk.result.links[key] ?? 0
        walk.result.simulatorCacheLinks.insert(key)
      }
    }
    for (key, remaining) in walk.remainingLinks where remaining != 0 {
      walk.result.sharedLinkBytes += walk.result.links[key] ?? 0
    }
    if walk.safeRoot {
      walk.result.cleanupReadings[root.url.path] = DirectoryReading(
        info, bytes: walk.result.bytes,
        files: walk.result.files,
        verified: walk.unsafeEntries == 0 && walk.result.missed == 0
          && walk.remainingLinks.isEmpty && !walk.result.unexpectedDownloads
          && info.st_uid == getuid())
    }
    if walk.result.missed > 0 && walk.result.state == .complete { walk.result.state = .partial }
    walk.result.finishBreakdown()
    return walk.result
  }

  private struct Walk {
    let caseInsensitiveCleanup: Bool
    let captureBranches: Bool
    let user = getuid()
    let rootPath: String
    let safeRoot: Bool
    let projectOutput: Bool
    let allowSymlinks: Bool
    var unsafeEntries = 0
    var linkedEntries = 0
    var remainingLinks: [FileKey: Int] = [:]
    let trackLinks: Bool
    var pathComponents: [String] = []
    let device: dev_t
    let project: Bool
    let download: PackageDownloadCache?
    let ageCutoff: Date?
    var result = RootSize()
    var outputLinks = Set<FileKey>()
    var cacheLinks: [FileKey: (seen: Int, expected: Int)] = [:]

    /// Takes ownership of fd, even if enumeration fails or is cancelled.
    mutating func visit(
      _ fd: Int32, level: Int, branch: String, output: String?, sourceTree: Bool,
      scope: SimulatorDirectory, exclusions: [ArraySlice<Substring>], downloadPrefix: String = "",
      patterns: [ArraySlice<Substring>] = [], branchPath: String? = nil
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
            if let download, !result.unexpectedDownloads {
              let regular = info.st_mode & S_IFMT == S_IFREG
              let directory = info.st_mode & S_IFMT == S_IFDIR
              result.unexpectedDownloads =
                info.st_dev != device || info.st_uid != user || !(regular || directory)
                || !download.accepts(
                  String(cString: name), directory: directory, prefix: downloadPrefix)
            }
            let type = info.st_mode & S_IFMT
            if safeRoot || scope == .cache {
              if info.st_uid != user || info.st_dev != device
                || !(type == S_IFDIR || type == S_IFREG || (allowSymlinks && type == S_IFLNK))
              {
                unsafeEntries += 1
              }
            }
            guard info.st_dev == device else { return }
            guard type == S_IFDIR || type == S_IFREG else { return }
            let needsName =
              level == 0 || !exclusions.isEmpty
              || (type == S_IFDIR
                && ((project && output == nil) || scope.checksChildName || !exclusions.isEmpty
                  || download != nil || trackLinks || !patterns.isEmpty))
            let childName = needsName ? String(cString: name) : ""
            let bucket = level == 0 ? (type == S_IFDIR ? childName : "Kök dosyaları") : branch
            let nested = exclusions.compactMap { path in
              path.first == childName[...] ? path.dropFirst() : nil
            }
            if nested.contains(where: { $0.isEmpty }) { return }
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
              let nextScope = scope.descending(into: childName)
              let boundary = scope != .cache && nextScope == .cache
              let patternName =
                caseInsensitiveCleanup && !patterns.isEmpty ? childName.lowercased() : childName
              let matching = patterns.compactMap { pattern -> ArraySlice<Substring>? in
                guard let first = pattern.first else { return nil }
                let receipt =
                  first == "{receipt}" && childName.hasSuffix(")")
                  && childName.contains(" (MacPurge ")
                return first == "*" || receipt || first == patternName[...]
                  ? pattern.dropFirst() : nil
              }
              let keepPath = trackLinks || scope.checksChildName || boundary || !matching.isEmpty
              if keepPath { pathComponents.append(childName) }
              defer { if keepPath { pathComponents.removeLast() } }
              var segment = branchPath
              if matching.contains(where: { $0.isEmpty }) {
                let path =
                  (rootPath == "/" ? "" : rootPath) + "/" + pathComponents.joined(separator: "/")
                let key = caseInsensitiveCleanup ? path.lowercased() : path
                segment = key
                result.branches[key] = BranchReading(bucket: bucket)
              }
              let previousBytes = result.bytes
              let previousFiles = result.files
              let missed = result.missed
              let unsafe = unsafeEntries
              let linked = linkedEntries
              try visit(
                child, level: level + 1, branch: bucket,
                output: output
                  ?? (project && StorageMeter.outputFolders.contains(childName) ? childName : nil),
                sourceTree: sourceTree && childName != ".git",
                scope: nextScope, exclusions: nested,
                downloadPrefix: download == nil || result.unexpectedDownloads
                  ? "" : downloadPrefix + childName, patterns: matching, branchPath: segment)
              if level == 0 {
                result.recordDetail(
                  childName,
                  DirectoryReading(
                    opened, bytes: result.bytes - previousBytes,
                    files: result.files - previousFiles, verified: result.missed == missed))
              }
              if boundary {
                let path =
                  (rootPath == "/" ? "" : rootPath) + "/" + pathComponents.joined(separator: "/")
                result.cleanupReadings[path] = DirectoryReading(
                  opened, bytes: result.bytes - previousBytes,
                  files: result.files - previousFiles,
                  verified: missed == result.missed
                    && linked == linkedEntries && unsafe == unsafeEntries && opened.st_uid == user)
              }
              return
            }
            var branchPath = branchPath
            if patterns.contains(where: { $0.count == 1 && $0.first == "{receipt}" }) {
              let filename = String(cString: name)
              if filename.hasSuffix(")") && filename.contains(" (MacPurge ") {
                let path = ([rootPath] + pathComponents + [filename]).joined(separator: "/")
                let key = caseInsensitiveCleanup ? path.lowercased() : path
                branchPath = key
                result.branches[key] = BranchReading(bucket: bucket)
              }
            }
            let bytes = max(0, Int64(info.st_blocks)) * 512
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            if captureBranches {
              if let branchPath {
                result.branches[branchPath, default: BranchReading()].observe(
                  modified, output: output, source: sourceTree)
              } else {
                result.baselineDates.observe(modified, output: output, source: sourceTree)
              }
            }
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
              linkedEntries += 1
              if safeRoot || projectOutput {
                let remaining = (remainingLinks[key] ?? Int(info.st_nlink)) - 1
                remainingLinks[key] = remaining == 0 ? nil : remaining
              }
              if scope == .cache {
                let previous = cacheLinks[key] ?? (0, 0)
                cacheLinks[key] = (previous.seen + 1, max(previous.expected, Int(info.st_nlink)))
              }
              if let output, outputLinks.insert(key).inserted {
                result.outputBytes += bytes
                result.outputKinds[output, default: 0] += bytes
                if let branchPath {
                  result.branches[branchPath, default: BranchReading()].outputKinds[
                    output, default: 0] += bytes
                }
              }
              if result.links[key] != nil {
                if project { result.duplicateBytesByBranch[bucket, default: 0] += bytes }
                return
              }
              if trackLinks && result.linkChecks.count < MeasurementCache.linkLimit {
                let relative = (pathComponents + [String(cString: name)]).joined(separator: "/")
                result.linkChecks[key] = LinkCheck(path: relative, info: info)
              }
              result.links[key] = bytes
            } else {
              if scope == .cache { result.simulatorCacheBytes += bytes }
              if let output {
                result.outputBytes += bytes
                result.outputKinds[output, default: 0] += bytes
                if let branchPath {
                  result.branches[branchPath, default: BranchReading()].outputKinds[
                    output, default: 0] += bytes
                }
              }
            }
            if let ageCutoff {
              let timestamp =
                Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
              if timestamp >= ageCutoff.timeIntervalSince1970 {
                result.age?.recent += bytes
              } else {
                result.age?.older += bytes
              }
            }
            if let branchPath {
              result.branches[branchPath, default: BranchReading()].bytes += bytes
              result.branches[branchPath, default: BranchReading()].files += 1
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
